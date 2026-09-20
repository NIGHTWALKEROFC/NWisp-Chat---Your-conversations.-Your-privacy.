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

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { generatePasswordResetLink, resolveAccount } from "../_shared/firebase_admin.ts";
import { otpEmailHtml, otpEmailText, resetPasswordEmailHtml, resetPasswordEmailText, sendEmail } from "../_shared/email.ts";
import { bumpThrottle, describeWait, subjectsFor } from "../_shared/abuse_throttle.ts";

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
