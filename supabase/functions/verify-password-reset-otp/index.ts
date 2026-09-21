// The second half of "Reset with a code". Two uses, chosen by whether
// `newPassword` is present:
//
//   POST { email, code }                 CHECK ONLY
//        -> 200 { verified: true }       the code is right (NOT used up), so the app
//                                        can show its boxes green and move on
//   POST { email, code, newPassword }    RESET
//        -> 200 { reset: true }          the code is right: the password is changed
//                                        and the code is deleted (single use)
//
// `email` may be an email address OR a username (whatever was typed on the
// reset screen) — it's resolved to the account here, the same way
// send-password-reset does.
//
// A code is 6 digits, lives 10 minutes, and allows 5 wrong tries. Every
// failure gets one uniform message so this can't be used to probe.
//
// Public / unauthenticated. Deployed with verify_jwt = false (see supabase/config.toml).

// SINGLE-FILE VERSION.
// Everything this function needs is inlined below, so it deploys from the
// Supabase dashboard editor (which only bundles this one file and can't find
// "../_shared/..." imports) as well as from the CLI. The helper sections are
// copies of supabase/functions/_shared/{firebase_admin,email,abuse_throttle}.ts
// — if you ever change those, this file does NOT pick the change up.
//
// Secrets it reads (all already used by your other functions):
//   FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT_EMAIL, FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY,
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//
// Deploy with "Verify JWT" OFF (it is called before anyone is signed in).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@5";

// ==========================================================================
// Firebase Auth admin helpers (from _shared/firebase_admin.ts)
// ==========================================================================
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const SERVICE_ACCOUNT_EMAIL = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_EMAIL")!;
const SERVICE_ACCOUNT_PRIVATE_KEY = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY")!.replace(/\\n/g, "\n");

const TOKEN_URL = "https://oauth2.googleapis.com/token";

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getIdentityToolkitAccessToken(): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + 30_000) {
    return cachedToken.token;
  }
  const privateKey = await jose.importPKCS8(SERVICE_ACCOUNT_PRIVATE_KEY, "RS256");
  const now = Math.floor(Date.now() / 1000);
  const assertion = await new jose.SignJWT({
    scope: "https://www.googleapis.com/auth/identitytoolkit",
  })
    .setProtectedHeader({ alg: "RS256" })
    .setIssuer(SERVICE_ACCOUNT_EMAIL)
    .setSubject(SERVICE_ACCOUNT_EMAIL)
    .setAudience(TOKEN_URL)
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(privateKey);

  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) throw new Error(`Google token exchange failed: ${await res.text()}`);
  const data = await res.json();
  cachedToken = { token: data.access_token, expiresAt: Date.now() + data.expires_in * 1000 };
  return data.access_token;
}

async function resolveAccount(identifier: string): Promise<{ localId: string; email: string } | null> {
  const typed = identifier.trim();
  if (!typed) return null;
  const accessToken = await getIdentityToolkitAccessToken();

  let query: Record<string, string[]>;
  if (typed.includes("@")) {
    query = { email: [typed.toLowerCase()] };
  } else {
    const name = typed.toLowerCase();
    const res = await fetch(
      `https://firestore.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/databases/(default)/documents/usernames/${encodeURIComponent(name)}`,
    );
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`usernames lookup failed: ${await res.text()}`);
    const doc = await res.json();
    const uid = doc?.fields?.uid?.stringValue as string | undefined;
    if (!uid) return null;
    query = { localId: [uid] };
  }

  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:lookup", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify(query),
  });
  if (!res.ok) throw new Error(`accounts:lookup failed: ${await res.text()}`);
  const data = await res.json();
  const user = data.users?.[0];
  if (!user?.email) return null;
  return { localId: user.localId as string, email: String(user.email).toLowerCase() };
}

async function setUserPassword(uid: string, newPassword: string): Promise<void> {
  const accessToken = await getIdentityToolkitAccessToken();
  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:update", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ localId: uid, password: newPassword }),
  });
  if (!res.ok) throw new Error(`accounts:update (password) failed: ${await res.text()}`);
}

// ==========================================================================
// Abuse throttle (from _shared/abuse_throttle.ts)
// ==========================================================================


const FIRST_BLOCK_SECONDS = 60 * 60;
const REPEAT_BLOCK_SECONDS = 24 * 60 * 60;

function clientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim() || null;
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip");
}

function subjectsFor(req: Request, deviceId: unknown): string[] {
  const subjects: string[] = [];
  const ip = clientIp(req);
  if (ip) subjects.push(`ip:${ip}`);
  if (typeof deviceId === "string" && deviceId.length >= 8 && deviceId.length <= 100) {
    subjects.push(`device:${deviceId}`);
  }
  return subjects;
}

/** Counts one attempt for each subject. Returns how long the caller must wait
 *  (seconds) if ANY subject is blocked, otherwise null. */
async function bumpThrottle(
  supabase: SupabaseClient,
  subjects: string[],
  action: string,
  opts: { limit: number; windowSeconds: number },
): Promise<number | null> {
  let worstWait: number | null = null;
  const now = Date.now();

  for (const subject of subjects) {
    const { data: row } = await supabase
      .from("abuse_throttle")
      .select("count, window_started_at, escalation_level, blocked_until")
      .eq("subject", subject)
      .eq("action", action)
      .maybeSingle();

    if (row?.blocked_until) {
      const until = new Date(row.blocked_until).getTime();
      if (until > now) {
        worstWait = Math.max(worstWait ?? 0, Math.ceil((until - now) / 1000));
        continue;
      }
    }

    const windowStart = row ? new Date(row.window_started_at).getTime() : now;
    const windowExpired = !row || now - windowStart > opts.windowSeconds * 1000;
    const count = windowExpired ? 1 : (row!.count ?? 0) + 1;
    const level = row?.escalation_level ?? 0;

    if (count > opts.limit) {
      const newLevel = level + 1;
      const blockSeconds = newLevel <= 1 ? FIRST_BLOCK_SECONDS : REPEAT_BLOCK_SECONDS;
      await supabase.from("abuse_throttle").upsert({
        subject,
        action,
        count: 0,
        window_started_at: new Date(now).toISOString(),
        escalation_level: newLevel,
        blocked_until: new Date(now + blockSeconds * 1000).toISOString(),
      });
      worstWait = Math.max(worstWait ?? 0, blockSeconds);
    } else {
      await supabase.from("abuse_throttle").upsert({
        subject,
        action,
        count,
        window_started_at: new Date(windowExpired ? now : windowStart).toISOString(),
        escalation_level: level,
        blocked_until: null,
      });
    }
  }
  return worstWait;
}

function describeWait(seconds: number): string {
  if (seconds < 90) return `${seconds} seconds`;
  if (seconds < 5400) return `${Math.ceil(seconds / 60)} minutes`;
  if (seconds < 172800) return `${Math.ceil(seconds / 3600)} hours`;
  return `${Math.ceil(seconds / 86400)} days`;
}

// ==========================================================================
// The function
// ==========================================================================
const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const MAX_ATTEMPTS = 5;
const MIN_PASSWORD_LENGTH = 6; // Firebase's own minimum
const BAD_CODE = "Incorrect or expired code.";

function reply(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function hashCode(code: string, email: string): Promise<string> {
  const data = new TextEncoder().encode(`${email}:password-reset:${code}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    const identifier = typeof body?.email === "string" ? body.email : body?.identifier;
    const rawCode = body?.code;
    if (typeof identifier !== "string" || identifier.trim().length === 0 || typeof rawCode !== "string") {
      return reply({ error: "Invalid request." }, 400);
    }
    const code = rawCode.trim();
    if (!/^\d{6}$/.test(code)) return reply({ error: BAD_CODE }, 400);

    // Generous per-network cap on top of the 5-tries-per-code limit below.
    const wait = await bumpThrottle(supabase, subjectsFor(req, body?.deviceId), "password_reset_verify", {
      limit: 40,
      windowSeconds: 60 * 60,
    });
    if (wait !== null) return reply({ error: `Too many attempts. Try again in ${describeWait(wait)}.` }, 429);

    const account = await resolveAccount(identifier).catch(() => null);
    if (!account) return reply({ error: BAD_CODE }, 400);
    const email = account.email;

    const { data: row } = await supabase
      .from("password_reset_otps")
      .select("code_hash, attempts, expires_at")
      .eq("email", email)
      .maybeSingle();
    if (!row || new Date(row.expires_at).getTime() < Date.now()) return reply({ error: BAD_CODE }, 400);
    if (row.attempts >= MAX_ATTEMPTS) {
      return reply({ error: "Too many incorrect attempts. Request a new code." }, 429);
    }
    if ((await hashCode(code, email)) !== row.code_hash) {
      await supabase.from("password_reset_otps").update({ attempts: row.attempts + 1 }).eq("email", email);
      return reply({ error: BAD_CODE }, 400);
    }

    // Code is correct.
    const newPassword = body?.newPassword;
    if (newPassword === undefined || newPassword === null) {
      return reply({ verified: true }); // check only — nothing consumed
    }
    if (typeof newPassword !== "string" || newPassword.length < MIN_PASSWORD_LENGTH) {
      return reply({ error: `Choose a password of at least ${MIN_PASSWORD_LENGTH} characters.` }, 400);
    }
    await setUserPassword(account.localId, newPassword);
    await supabase.from("password_reset_otps").delete().eq("email", email); // single use
    return reply({ reset: true });
  } catch (_err) {
    return reply({ error: "Something went wrong. Please try again." }, 500);
  }
});
