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

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { resolveAccount, setUserPassword } from "../_shared/firebase_admin.ts";
import { bumpThrottle, describeWait, subjectsFor } from "../_shared/abuse_throttle.ts";

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
