// Sends real email through a normal Gmail account's SMTP server (free —
// no Firebase Blaze plan, no domain purchase, no third-party email API
// account needed). This is the whole fix for "everything lands in spam":
// Firebase Auth's own built-in emails come from its shared, low-reputation
// noreply@<project-id>.firebaseapp.com sender — mail providers see that
// domain from thousands of unrelated apps and treat it with suspicion. A
// normal Gmail address sending a handful of emails a day already has a
// good sender reputation and Google's own SPF/DKIM/DMARC behind it, so
// these land in the inbox instead.
//
// Needs a Gmail "App Password" (NOT your normal Gmail password — see
// EMAIL_SETUP.md step 1). Two secrets:
//   GMAIL_ADDRESS         e.g. nwisp.app@gmail.com
//   GMAIL_APP_PASSWORD    the 16-character app password
// Optional:
//   EMAIL_FROM_NAME       display name, defaults to "NWisp"
//
// Gmail's free sending cap is ~500 emails/day per account — fine for a
// still-in-production app; EMAIL_SETUP.md notes this and how to raise it
// later (a Google Workspace account) if the app grows.

import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

const GMAIL_ADDRESS = Deno.env.get("GMAIL_ADDRESS")!;
const GMAIL_APP_PASSWORD = Deno.env.get("GMAIL_APP_PASSWORD")!;
const FROM_NAME = Deno.env.get("EMAIL_FROM_NAME") ?? "NWisp";

// Matches AppTheme.defaultSeedColor / AppTheme.darkSurface in
// mobile/lib/theme/app_theme.dart, so the emails look like they came
// from the same app instead of a generic template.
const BRAND_TEAL = "#00C896";
const BRAND_DARK = "#0D1117";

export async function sendEmail(opts: { to: string; subject: string; html: string; text: string }): Promise<void> {
  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: GMAIL_ADDRESS, password: GMAIL_APP_PASSWORD },
    },
    // Fixes stray "=20" (and similar =XX escapes) showing up at line
    // breaks in the received email: denomailer quoted-printable-encodes
    // the body, and without this flag it doesn't correctly encode line
    // breaks, so some mail clients render the raw escape codes instead of
    // decoding them. This forces line breaks to be encoded properly.
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

export function otpEmailHtml(code: string, purpose: "signup" | "password reset"): string {
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

export function otpEmailText(code: string, purpose: "signup" | "password reset"): string {
  const heading = purpose === "signup" ? "Confirm your email for NWisp" : "Your NWisp verification code";
  return `${heading}\n\nYour code: ${code}\n\nThis code expires in 10 minutes. Never share it with anyone.\n\nIf you didn't request this, you can ignore this email.`;
}

export function resetPasswordEmailHtml(link: string): string {
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

export function resetPasswordEmailText(link: string): string {
  return `Reset your NWisp password\n\nWe got a request to reset the password for your NWisp account. Open this link to choose a new one (expires in 1 hour, single use):\n\n${link}\n\nIf you didn't request this, you can ignore this email.`;
}
