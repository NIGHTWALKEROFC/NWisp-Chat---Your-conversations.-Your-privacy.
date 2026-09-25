// Feature: CAPTCHA (Cloudflare Turnstile) — verifies the token the app
// got from solving the Turnstile widget (see
// mobile/lib/widgets/turnstile_captcha.dart) against Cloudflare's
// siteverify API. This is the step that actually matters: the token
// itself is just something the client hands back, so trusting it without
// this server-side check would make the whole CAPTCHA pointless.
//
// Free forever on Cloudflare's "Managed" widget — no paid plan needed.
//
// Secret used: CF_TURNSTILE_SECRET_KEY (set in Supabase Edge Function
// secrets — see the setup steps). Never put the secret key in the app;
// only the public SITE key goes there.
//
// NOTE: this file is imported (`../_shared/turnstile.ts`) by
// send-signup-otp, which deploys fine from the CLI. send-password-reset
// is a SINGLE-FILE function (so it also works from the Supabase dashboard
// editor) and therefore keeps its OWN inlined copy of this same logic
// instead of importing this file — if you ever change the logic here,
// make the same change there.

const TURNSTILE_SECRET_KEY = Deno.env.get("CF_TURNSTILE_SECRET_KEY")!;
const VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

export async function verifyTurnstileToken(token: unknown, remoteIp: string | null): Promise<boolean> {
  if (typeof token !== "string" || token.length === 0 || token.length > 2048) {
    return false;
  }
  try {
    const body = new URLSearchParams();
    body.set("secret", TURNSTILE_SECRET_KEY);
    body.set("response", token);
    if (remoteIp) body.set("remoteip", remoteIp);

    const res = await fetch(VERIFY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    if (!res.ok) return false;
    const data = await res.json();
    return data?.success === true;
  } catch (_err) {
    // Cloudflare unreachable, malformed response, etc. — fail closed
    // (treat as NOT verified) rather than silently letting abuse through.
    return false;
  }
}

/** Same client-IP extraction send-password-reset's abuse_throttle already
 *  uses, duplicated here so this helper has no other imports. */
export function clientIpFor(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim() || null;
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip");
}
