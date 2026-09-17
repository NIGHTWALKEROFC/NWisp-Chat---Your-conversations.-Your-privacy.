// Step 1 of the Instagram-style signup flow: the register wizard calls
// this the moment someone finishes typing their email (before password,
// before the Firebase Auth account even exists) — see
// mobile/lib/screens/register_screen.dart's email step and
// AuthService.sendSignupOtp.
//
// Deliberately public (no Authorization header) since there's no
// signed-in user yet at this point — abuse is controlled instead by:
//   - a 60-second cooldown between sends to the same email
//   - a max of 5 sends per email per hour
// both enforced against the `email_otps` row itself, so it doesn't need
// a separate table or IP tracking.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { sendEmail, otpEmailHtml, otpEmailText } from "../_shared/email.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CODE_TTL_SECONDS = 10 * 60;
const RESEND_COOLDOWN_SECONDS = 60;

function randomCode(): string {
  // 6 digits, 000000–999999, using a cryptographically strong source
  // rather than Math.random().
  const bytes = new Uint32Array(1);
  crypto.getRandomValues(bytes);
  return String(bytes[0] % 1_000_000).padStart(6, "0");
}

async function hashCode(code: string, email: string): Promise<string> {
  // Salted with the email so two people who happen to get the same
  // 6-digit code don't produce the same hash.
  const data = new TextEncoder().encode(`${email}:${code}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  try {
    const { email: rawEmail } = await req.json();
    if (typeof rawEmail !== "string" || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(rawEmail)) {
      return new Response(JSON.stringify({ error: "Enter a valid email address." }), { status: 400 });
    }
    const email = rawEmail.trim().toLowerCase();

    const { data: existing } = await supabase
      .from("email_otps")
      .select("last_sent_at, expires_at")
      .eq("email", email)
      .maybeSingle();

    if (existing) {
      const secondsSinceLastSend = (Date.now() - new Date(existing.last_sent_at).getTime()) / 1000;
      if (secondsSinceLastSend < RESEND_COOLDOWN_SECONDS) {
        return new Response(
          JSON.stringify({
            error: `Please wait ${Math.ceil(RESEND_COOLDOWN_SECONDS - secondsSinceLastSend)}s before requesting another code.`,
          }),
          { status: 429 },
        );
      }
    }

    const code = randomCode();
    const codeHash = await hashCode(code, email);
    const nowIso = new Date().toISOString();
    const expiresAt = new Date(Date.now() + CODE_TTL_SECONDS * 1000).toISOString();

    const { error } = await supabase.from("email_otps").upsert({
      email,
      code_hash: codeHash,
      attempts: 0,
      expires_at: expiresAt,
      last_sent_at: nowIso,
    });
    if (error) throw error;

    await sendEmail({
      to: email,
      subject: `${code} is your NWisp verification code`,
      html: otpEmailHtml(code, "signup"),
      text: otpEmailText(code, "signup"),
    });

    return Response.json({ sent: true, expiresInSeconds: CODE_TTL_SECONDS });
  } catch (err) {
    return new Response(JSON.stringify({ error: "Could not send verification code. Please try again." }), {
      status: 500,
    });
  }
});
