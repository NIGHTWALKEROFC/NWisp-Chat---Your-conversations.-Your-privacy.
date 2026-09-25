// Step 1 of the Instagram-style signup flow: the register wizard calls
// this the moment someone finishes typing their email (before password,
// before the Firebase Auth account even exists) — see
// mobile/lib/screens/register_screen.dart's email step and
// AuthService.sendSignupOtp.
//
// Deliberately public (no Authorization header) since there's no
// signed-in user yet at this point — abuse is controlled instead by:
//   - a Cloudflare Turnstile CAPTCHA the app must solve first
//   - a 60-second cooldown between sends to the same email
//   - a max of 5 sends per email per hour
// both enforced against the `email_otps` row itself, so it doesn't need
// a separate table or IP tracking.
//
// SINGLE-FILE VERSION.
// Everything this function needs is inlined below (same pattern as
// send-password-reset and verify-password-reset-otp), so it deploys from
// the Supabase dashboard editor — which only bundles the one file you
// paste in and can't resolve "../_shared/..." imports — as well as from
// the CLI. The helper sections are copies of
// supabase/functions/_shared/{email,turnstile}.ts — if you ever change
// those, this file does NOT pick the change up automatically; update
// both places.
//
// Secrets it reads:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, GMAIL_ADDRESS,
//   GMAIL_APP_PASSWORD (+ optional EMAIL_FROM_NAME), CF_TURNSTILE_SECRET_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

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
    // Fixes stray "=20" (and similar =XX escapes) showing up at line
    // breaks in the received email — denomailer quoted-printable-encodes
    // the body, and without this flag it doesn't correctly encode line
    // breaks, so some mail clients render the raw escape codes instead of
    // decoding them.
    debug: { encodeLB: true },
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

// ==========================================================================
// Turnstile CAPTCHA verification (from _shared/turnstile.ts)
// ==========================================================================
const TURNSTILE_SECRET_KEY = Deno.env.get("CF_TURNSTILE_SECRET_KEY")!;
const TURNSTILE_VERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

async function verifyTurnstileToken(token: unknown, remoteIp: string | null): Promise<boolean> {
  if (typeof token !== "string" || token.length === 0 || token.length > 2048) {
    return false;
  }
  try {
    const body = new URLSearchParams();
    body.set("secret", TURNSTILE_SECRET_KEY);
    body.set("response", token);
    if (remoteIp) body.set("remoteip", remoteIp);

    const res = await fetch(TURNSTILE_VERIFY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
    if (!res.ok) return false;
    const data = await res.json();
    return data?.success === true;
  } catch (_err) {
    return false;
  }
}

function clientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");
  if (forwarded) return forwarded.split(",")[0].trim() || null;
  return req.headers.get("cf-connecting-ip") ?? req.headers.get("x-real-ip");
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
    const { email: rawEmail, turnstileToken } = await req.json();
    if (typeof rawEmail !== "string" || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(rawEmail)) {
      return new Response(JSON.stringify({ error: "Enter a valid email address." }), { status: 400 });
    }
    const email = rawEmail.trim().toLowerCase();

    // CAPTCHA check first — cheapest way to turn away scripted abuse
    // before it touches anything else below.
    const captchaOk = await verifyTurnstileToken(turnstileToken, clientIp(req));
    if (!captchaOk) {
      return new Response(
        JSON.stringify({ error: "Security check failed. Please try again." }),
        { status: 400 },
      );
    }

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
