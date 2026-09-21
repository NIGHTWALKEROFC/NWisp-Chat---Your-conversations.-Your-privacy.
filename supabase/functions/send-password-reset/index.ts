// Sends the person a way to reset their password — either a 6-DIGIT CODE or an
// emailed LINK — depending on what they chose on the Reset password screen.
//
//   POST { identifier, deviceId?, method? }
//     identifier : an email address OR a username
//     deviceId   : this phone's persisted id (used for abuse throttling)
//     method     : 'otp'   -> email a 6-digit code (finish in the app)
//                  'email' -> email a "Reset your password" button/link
//                  omitted -> 'email'
//   -> 200 { mode: 'otp' | 'email', message }
//
// The app ALWAYS asks which method the person wants, so `method` is normally
// present. `mode` in the reply says what was ACTUALLY sent, and the app
// follows that.
//
// Kept on purpose (same product choice as the app's own comment on
// AuthService.requestPasswordReset): if nothing matches the identifier this
// says so outright instead of a vague "if an account exists...". That makes it
// possible to discover which emails/usernames are registered, so it's paired
// with abuse throttling (per network AND per device, escalating 1 hour then 1
// day — see _shared/abuse_throttle.ts) and a per-address cooldown.
//
// Public / unauthenticated (nobody is signed in at "forgot password").
// Deployed with verify_jwt = false (see supabase/config.toml).

// SINGLE-FILE VERSION.
// Everything this function needs is inlined below, so it deploys from the
// Supabase dashboard editor (which only bundles this one file and can't find
// "../_shared/..." imports) as well as from the CLI. The helper sections are
// copies of supabase/functions/_shared/{firebase_admin,email,abuse_throttle}.ts
// — if you ever change those, this file does NOT pick the change up.
//
// Secrets it reads (all already used by your other functions):
//   FIREBASE_PROJECT_ID, FIREBASE_SERVICE_ACCOUNT_EMAIL, FIREBASE_SERVICE_ACCOUNT_PRIVATE_KEY,
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GMAIL_ADDRESS, GMAIL_APP_PASSWORD (+ optional EMAIL_FROM_NAME)
//
// Deploy with "Verify JWT" OFF (it is called before anyone is signed in).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@5";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

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

async function generatePasswordResetLink(email: string): Promise<string> {
  const accessToken = await getIdentityToolkitAccessToken();
  const res = await fetch("https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode", {
    method: "POST",
    headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ requestType: "PASSWORD_RESET", email, returnOobLink: true }),
  });
  if (!res.ok) throw new Error(`accounts:sendOobCode failed: ${await res.text()}`);
  const data = await res.json();
  return data.oobLink as string;
}

// ==========================================================================
// Email helpers (from _shared/email.ts)
// ==========================================================================
const GMAIL_ADDRESS = Deno.env.get("GMAIL_ADDRESS")!;
const GMAIL_APP_PASSWORD = Deno.env.get("GMAIL_APP_PASSWORD")!;
const FROM_NAME = Deno.env.get("EMAIL_FROM_NAME") ?? "NWisp";

const BRAND_TEAL = "#00C896";
const BRAND_DARK = "#0D1117";

async function sendEmail(opts: { to: string; subject: string; html: string; text: string }): Promise<void> {
  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_ADDRESS, password: GMAIL_APP_PASSWORD },
    },
  });
  try {
    await client.send({
      from: `${FROM_NAME} <${GMAIL_ADDRESS}>`,
      to: opts.to,
      subject: opts.subject,
      content: opts.text,
      html: opts.html,
    });
  } finally {
    await client.close();
  }
}

function shell(preheader: string, bodyHtml: string): string {
  return `<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>NWisp</title>
  </head>
  <body style="margin:0; padding:0; background:#f2f2f5; font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <div style="display:none; max-height:0; overflow:hidden;">${preheader}</div>
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f5; padding:32px 0;">
      <tr>
        <td align="center">
          <table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:${BRAND_DARK}; border-radius:16px; overflow:hidden;">
            <tr>
              <td style="padding:28px 32px 8px 32px;">
                <span style="color:#ffffff; font-size:20px; font-weight:700; letter-spacing:0.3px;">NWisp</span>
                <div style="color:#8b949e; font-size:12px; margin-top:2px;">Your conversations. Your privacy.</div>
              </td>
            </tr>
            <tr>
              <td style="padding:8px 32px 32px 32px; color:#e6edf3; font-size:15px; line-height:1.6;">
                ${bodyHtml}
              </td>
            </tr>
          </table>
          <div style="color:#9aa0a6; font-size:12px; margin-top:16px; max-width:480px;">
            If you didn't request this, you can safely ignore this email.
          </div>
        </td>
      </tr>
    </table>
  </body>
</html>`;
}

function otpEmailHtml(code: string, purpose: "signup" | "password reset"): string {
  const heading = purpose === "signup" ? "Confirm your email" : "Your verification code";
  const body = `
    <p style="margin:0 0 18px 0;">${heading} for <strong>NWisp</strong> by entering this code in the app:</p>
    <div style="background:#161b22; border:1px solid #30363d; border-radius:12px; padding:20px; text-align:center; margin:0 0 18px 0;">
      <span style="font-size:32px; font-weight:700; letter-spacing:10px; color:${BRAND_TEAL};">${code}</span>
    </div>
    <p style="margin:0; color:#8b949e; font-size:13.5px;">This code expires in 10 minutes. Never share it with anyone — NWisp staff will never ask you for it.</p>
  `;
  return shell(`Your NWisp verification code is ${code}`, body);
}

function otpEmailText(code: string, purpose: "signup" | "password reset"): string {
  const heading = purpose === "signup" ? "Confirm your email for NWisp" : "Your NWisp verification code";
  return `${heading}\n\nYour code: ${code}\n\nThis code expires in 10 minutes. Never share it with anyone.\n\nIf you didn't request this, you can ignore this email.`;
}

function resetPasswordEmailHtml(link: string): string {
  const body = `
    <p style="margin:0 0 18px 0;">We got a request to reset the password for your <strong>NWisp</strong> account.</p>
    <div style="text-align:center; margin:0 0 20px 0;">
      <a href="${link}" style="display:inline-block; background:${BRAND_TEAL}; color:#04120c; font-weight:700; text-decoration:none; padding:14px 28px; border-radius:10px; font-size:15px;">
        Reset your password
      </a>
    </div>
    <p style="margin:0 0 6px 0; color:#8b949e; font-size:13.5px;">This link expires in 1 hour and can only be used once.</p>
    <p style="margin:0; color:#8b949e; font-size:12.5px; word-break:break-all;">Button not working? Paste this into your browser:<br/>${link}</p>
  `;
  return shell("Reset your NWisp password", body);
}

function resetPasswordEmailText(link: string): string {
  return `Reset your NWisp password\n\nWe got a request to reset the password for your NWisp account. Open this link to choose a new one (expires in 1 hour, single use):\n\n${link}\n\nIf you didn't request this, you can ignore this email.`;
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

const CODE_TTL_SECONDS = 10 * 60;
const RESEND_COOLDOWN_SECONDS = 60;
const MAX_REQUESTS_PER_HOUR_PER_EMAIL = 5;
const THROTTLE = { limit: 8, windowSeconds: 60 * 60 };

function reply(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

function randomCode(): string {
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  return String(bytes[0] % 1_000_000).padStart(6, "0");
}

async function hashCode(code: string, email: string): Promise<string> {
  // Salted with the email, and with a purpose label so a password-reset code
  // and a signup code can never stand in for each other.
  const data = new TextEncoder().encode(`${email}:password-reset:${code}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  try {
    const body = await req.json();
    // `email` is accepted too, so an older app build that still sends it keeps working.
    const identifier = typeof body?.identifier === "string" ? body.identifier : body?.email;
    if (typeof identifier !== "string" || identifier.trim().length === 0 || identifier.length > 254) {
      return reply({ error: "Enter your email or username." }, 400);
    }
    const method = body?.method === "otp" ? "otp" : "email";

    // 1. Network + device throttle.
    const wait = await bumpThrottle(supabase, subjectsFor(req, body?.deviceId), "password_reset", THROTTLE);
    if (wait !== null) {
      return reply({ error: `Too many reset requests. Please try again in ${describeWait(wait)}.` }, 429);
    }

    // 2. Who is this?
    const account = await resolveAccount(identifier).catch(() => null);
    if (!account) {
      return reply({ error: "No account found with that email or username." }, 400);
    }
    const email = account.email;

    // 3. Per-address cooldown + hourly cap (counted from the request log).
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const { data: recent } = await supabase
      .from("password_reset_requests")
      .select("requested_at")
      .eq("email", email)
      .gte("requested_at", oneHourAgo)
      .order("requested_at", { ascending: false });
    const requests = recent ?? [];
    if (requests.length > 0) {
      const secondsSinceLast = (Date.now() - new Date(requests[0].requested_at).getTime()) / 1000;
      if (secondsSinceLast < RESEND_COOLDOWN_SECONDS) {
        return reply(
          { error: `Please wait ${Math.ceil(RESEND_COOLDOWN_SECONDS - secondsSinceLast)}s before requesting again.` },
          429,
        );
      }
    }
    if (requests.length >= MAX_REQUESTS_PER_HOUR_PER_EMAIL) {
      return reply({ error: "Too many reset requests for this account. Please try again later." }, 429);
    }
    await supabase.from("password_reset_requests").insert({ email, requested_at: new Date().toISOString() });

    // 4a. A 6-digit code.
    if (method === "otp") {
      const code = randomCode();
      const { error } = await supabase.from("password_reset_otps").upsert({
        email,
        code_hash: await hashCode(code, email),
        attempts: 0,
        expires_at: new Date(Date.now() + CODE_TTL_SECONDS * 1000).toISOString(),
        last_sent_at: new Date().toISOString(),
      });
      if (error) throw error;
      await sendEmail({
        to: email,
        subject: `${code} is your NWisp password reset code`,
        html: otpEmailHtml(code, "password reset"),
        text: otpEmailText(code, "password reset"),
      });
      return reply({ mode: "otp", message: "We've emailed you a 6-digit code.", expiresInSeconds: CODE_TTL_SECONDS });
    }

    // 4b. The emailed link (the original flow).
    const link = await generatePasswordResetLink(email);
    await sendEmail({
      to: email,
      subject: "Reset your NWisp password",
      html: resetPasswordEmailHtml(link),
      text: resetPasswordEmailText(link),
    });
    return reply({ mode: "email", message: "We've emailed you a reset link." });
  } catch (_err) {
    return reply({ error: "Something went wrong. Please try again." }, 500);
  }
});
