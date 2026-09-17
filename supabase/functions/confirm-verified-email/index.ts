// Step 3 of the signup flow, and the only one of the three that's
// authenticated: called by AuthService.registerWithEmail right after
// createUserWithEmailAndPassword succeeds. It looks up the
// `verified_emails` stamp verify-signup-otp left behind for this same
// email, checks it's unused and not expired, marks it consumed, and — if
// all that checks out — calls the Identity Toolkit admin API to flip
// emailVerified to true on the brand-new account. This is the step that
// ties "we verified this email" to "this specific uid owns it": nobody
// can redeem someone else's OTP confirmation for their own account,
// because the email in their ID token has to match exactly.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { verifyIdToken, markEmailVerified, AuthTokenError } from "../_shared/firebase_admin.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (req) => {
  try {
    const { uid, email } = await verifyIdToken(req);
    if (!email) {
      return new Response(JSON.stringify({ error: "This account has no email on its token." }), { status: 400 });
    }
    const normalizedEmail = email.trim().toLowerCase();

    const { data: row } = await supabase
      .from("verified_emails")
      .select("expires_at, consumed")
      .eq("email", normalizedEmail)
      .maybeSingle();

    if (!row || row.consumed || new Date(row.expires_at).getTime() < Date.now()) {
      // Not an error the app needs to surface loudly — the account still
      // works either way, it just won't show as verified. Most likely
      // cause: they took >30 minutes between confirming the code and
      // finishing signup, or somehow skipped the OTP step.
      return Response.json({ confirmed: false });
    }

    await supabase.from("verified_emails").update({ consumed: true }).eq("email", normalizedEmail);
    await markEmailVerified(uid);

    return Response.json({ confirmed: true });
  } catch (err) {
    if (err instanceof AuthTokenError) {
      return new Response(JSON.stringify({ error: "Not signed in." }), { status: 401 });
    }
    return new Response(JSON.stringify({ error: "Could not confirm email verification." }), { status: 500 });
  }
});
