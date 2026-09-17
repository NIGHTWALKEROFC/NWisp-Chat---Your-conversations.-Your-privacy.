// Replaces AuthService.sendPasswordResetEmail (Firebase's own built-in
// reset email) end to end: this function generates the SAME kind of
// Firebase reset link Firebase would generate itself (via
// accounts:sendOobCode) but WITHOUT letting Firebase email it — instead
// we email it ourselves, through Gmail SMTP, as a branded "Reset your
// password" button. See ForgotPasswordScreen / AuthService.requestPasswordReset.
//
// The link itself points wherever Firebase Console > Authentication >
// Templates > Password reset > "Customize action URL" is set to — see
// EMAIL_SETUP.md step 5 for pointing that at docs/reset-password/
// (hosted free on GitHub Pages). That page reads the oobCode out of the
// link and lets the person type a new password directly — the
// "Instagram-style button that gets you in and lets you actually reset
// it" the person asked for, instead of a bare confirmation link.
//
// Public/unauthenticated (nobody's signed in yet at "forgot password").
// Deliberately gives the SAME response whether or not the email is
// registered — see [handle] — so this can't be used to check which
// emails have accounts (the exact same enumeration-safety note already
// on AuthService.isEmailLikelyAvailable applies here).

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { findUserByEmail, generatePasswordResetLink } from "../_shared/firebase_admin.ts";
import { sendEmail, resetPasswordEmailHtml, resetPasswordEmailText } from "../_shared/email.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const MAX_REQUESTS_PER_HOUR = 3;
const GENERIC_MESSAGE = "If an account exists for that email, we've sent password reset instructions.";

Deno.serve(async (req) => {
  try {
    const { email: rawEmail } = await req.json();
    if (typeof rawEmail !== "string" || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(rawEmail)) {
      return new Response(JSON.stringify({ error: "Enter a valid email address." }), { status: 400 });
    }
    const email = rawEmail.trim().toLowerCase();

    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const { count } = await supabase
      .from("password_reset_requests")
      .select("id", { count: "exact", head: true })
      .eq("email", email)
      .gte("requested_at", oneHourAgo);

    if ((count ?? 0) >= MAX_REQUESTS_PER_HOUR) {
      // Still the generic message — an attacker probing for which emails
      // are rate-limited would otherwise learn which emails exist.
      return Response.json({ message: GENERIC_MESSAGE });
    }

    await supabase.from("password_reset_requests").insert({ email, requested_at: new Date().toISOString() });

    const user = await findUserByEmail(email).catch(() => null);
    if (user) {
      const link = await generatePasswordResetLink(email);
      await sendEmail({
        to: email,
        subject: "Reset your NWisp password",
        html: resetPasswordEmailHtml(link),
        text: resetPasswordEmailText(link),
      });
    }

    return Response.json({ message: GENERIC_MESSAGE });
  } catch (_err) {
    // Even on an unexpected error, don't leak anything more specific —
    // the client shows the same friendly message either way.
    return Response.json({ message: GENERIC_MESSAGE });
  }
});
