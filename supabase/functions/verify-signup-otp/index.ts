// Step 2 of the Instagram-style signup flow: the register wizard calls
// this right after someone types in the 6-digit code they were emailed
// (see AuthService.verifySignupOtp). Still public/unauthenticated — same
// reason as send-signup-otp, there's no account yet.
//
// On success this writes a `verified_emails` row (valid 30 minutes,
// single-use) that confirm-verified-email later redeems once the actual
// Firebase Auth account has been created with this same email — that's
// what finally flips emailVerified to true on the real account.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const MAX_ATTEMPTS = 5;
const VERIFIED_TTL_SECONDS = 30 * 60;

async function hashCode(code: string, email: string): Promise<string> {
  const data = new TextEncoder().encode(`${email}:${code}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  try {
    const { email: rawEmail, code } = await req.json();
    if (typeof rawEmail !== "string" || typeof code !== "string") {
      return new Response(JSON.stringify({ error: "Invalid request." }), { status: 400 });
    }
    const email = rawEmail.trim().toLowerCase();

    const { data: row } = await supabase
      .from("email_otps")
      .select("code_hash, attempts, expires_at")
      .eq("email", email)
      .maybeSingle();

    if (!row) {
      return new Response(
        JSON.stringify({ error: "No verification code was requested for this email. Request a new one." }),
        { status: 400 },
      );
    }
    if (new Date(row.expires_at).getTime() < Date.now()) {
      return new Response(JSON.stringify({ error: "That code expired. Request a new one." }), { status: 400 });
    }
    if (row.attempts >= MAX_ATTEMPTS) {
      return new Response(
        JSON.stringify({ error: "Too many incorrect attempts. Request a new code." }),
        { status: 429 },
      );
    }

    const candidateHash = await hashCode(code.trim(), email);
    if (candidateHash !== row.code_hash) {
      await supabase.from("email_otps").update({ attempts: row.attempts + 1 }).eq("email", email);
      const remaining = MAX_ATTEMPTS - (row.attempts + 1);
      return new Response(
        JSON.stringify({
          error: remaining > 0 ? `Incorrect code. ${remaining} attempt(s) left.` : "Incorrect code. Request a new one.",
        }),
        { status: 400 },
      );
    }

    // Correct — this email is now confirmed. Consume the OTP row and
    // hand back a short-lived "this email is verified" stamp for
    // confirm-verified-email to redeem once the account actually exists.
    await supabase.from("email_otps").delete().eq("email", email);
    const { error } = await supabase.from("verified_emails").upsert({
      email,
      verified_at: new Date().toISOString(),
      expires_at: new Date(Date.now() + VERIFIED_TTL_SECONDS * 1000).toISOString(),
      consumed: false,
    });
    if (error) throw error;

    return Response.json({ verified: true });
  } catch (_err) {
    return new Response(JSON.stringify({ error: "Could not verify that code. Please try again." }), {
      status: 500,
    });
  }
});
