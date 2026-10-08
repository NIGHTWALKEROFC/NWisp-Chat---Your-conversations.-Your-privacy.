import * as jose from "https://esm.sh/jose@5";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

// Sends two security emails when someone asks to change the email address of a
// NWisp account:
//   * to the CURRENT address — this is the one that matters most. If the
//     request wasn't made by the real owner, they hear about it from an
//     address the attacker does not control and can change their password.
//   * to the NEW address — so a stranger's address can't be signed up
//     silently (the actual confirmation link comes separately from Firebase).
//
// The app calls this right before it asks Firebase to verify the new address
// (see AuthService.requestEmailChange). It is best-effort on the app's side:
// if this function is down, the change itself still works.
//
// This file is written to be pasted into the Supabase dashboard editor: it
// does not import anything from a shared folder.
//
// REQUIRED SECRETS (Edge Functions -> Secrets; the same ones your other email
// functions already use): FIREBASE_PROJECT_ID, GMAIL_ADDRESS, GMAIL_APP_PASSWORD
// (+ optional EMAIL_FROM_NAME).

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const GMAIL_ADDRESS = Deno.env.get("GMAIL_ADDRESS")!;
const GMAIL_APP_PASSWORD = Deno.env.get("GMAIL_APP_PASSWORD")!;
const FROM_NAME = Deno.env.get("EMAIL_FROM_NAME") ?? "NWisp";

const CALLER_JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

// Best-effort limit: 3 notices per account per hour, so this can't be used to
// flood anyone's inbox. (Resets if the function restarts — that's fine.)
const recent = new Map<string, number[]>();

function mask(email: string): string {
  const [name, domain] = email.split("@");
  if (!domain) return "***";
  const shown = name.length <= 2 ? name[0] ?? "" : name.slice(0, 2);
  return `${shown}***@${domain}`;
}

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

function shell(bodyHtml: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width, initial-scale=1"/><title>NWisp</title></head>
<body style="margin:0;padding:0;background:#f2f2f5;font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f5;padding:32px 0;"><tr><td align="center">
<table role="presentation" width="480" cellpadding="0" cellspacing="0" style="background:#0d1117;border-radius:16px;overflow:hidden;">
<tr><td style="padding:28px 32px 8px 32px;"><span style="color:#fff;font-size:20px;font-weight:700;">NWisp</span><div style="color:#8b949e;font-size:12px;margin-top:2px;">Your conversations. Your privacy.</div></td></tr>
<tr><td style="padding:8px 32px 32px 32px;color:#e6edf3;font-size:15px;line-height:1.6;">${bodyHtml}</td></tr>
</table></td></tr></table></body></html>`;
}

async function sendEmail(opts: { to: string; subject: string; html: string; text: string }): Promise<void> {
  const client = new SMTPClient({
    connection: { hostname: "smtp.gmail.com", port: 465, tls: true, auth: { username: GMAIL_ADDRESS, password: GMAIL_APP_PASSWORD } },
  });
  try {
    // Base64 bodies avoid the stray "=20" / "=3D" characters some mail apps show.
    await client.send({
      from: `${FROM_NAME} <${GMAIL_ADDRESS}>`,
      to: opts.to,
      subject: opts.subject,
      mimeContent: [
        { mimeType: 'text/plain; charset="utf-8"', content: opts.text, transferEncoding: "base64" },
        { mimeType: 'text/html; charset="utf-8"', content: opts.html, transferEncoding: "base64" },
      ],
    });
  } finally {
    await client.close();
  }
}

Deno.serve(async (req) => {
  try {
    const idToken = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { payload } = await jose.jwtVerify(idToken, CALLER_JWKS, {
      issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
      audience: FIREBASE_PROJECT_ID,
    });
    const uid = payload.sub as string;
    const currentEmail = String(payload.email ?? "");
    if (!currentEmail) return Response.json({ error: "no email on account" }, { status: 400 });

    const { newEmail } = await req.json();
    const next = String(newEmail ?? "").trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(next) || next.length > 200) {
      return Response.json({ error: "invalid email" }, { status: 400 });
    }
    if (next.toLowerCase() === currentEmail.toLowerCase()) {
      return Response.json({ error: "same email" }, { status: 400 });
    }

    const now = Date.now();
    const times = (recent.get(uid) ?? []).filter((t) => now - t < 3_600_000);
    if (times.length >= 3) return Response.json({ error: "too many requests" }, { status: 429 });
    times.push(now);
    recent.set(uid, times);

    const when = new Date().toUTCString();

    await sendEmail({
      to: currentEmail,
      subject: "Someone asked to change your NWisp email",
      text:
        `A request was made to change the email address of your NWisp account to ${mask(next)}.\n` +
        `Time: ${when}\n\nIf this was you, you don't need to do anything.\n` +
        `If it was NOT you, change your NWisp password right away (Settings > Account > Change password) and check Settings > Account > Devices.`,
      html: shell(
        `<h2 style="margin:0 0 12px 0;color:#fff;font-size:20px;">Email change requested</h2>
<p>A request was made to change the email address of your NWisp account to <b>${esc(mask(next))}</b>.</p>
<p style="color:#8b949e;font-size:13px;">Time: ${esc(when)}</p>
<p><b>If this was you</b>, you don't need to do anything.</p>
<p><b>If it was not you</b>, change your NWisp password right away (Settings &rarr; Account &rarr; Change password) and review your signed-in devices.</p>`,
      ),
    });

    await sendEmail({
      to: next,
      subject: "Your email was used for a NWisp account change",
      text:
        `Someone asked to use this email address (${mask(next)}) for a NWisp account.\n` +
        `A separate confirmation message with a link will arrive. If you don't recognise this, just ignore both messages — nothing changes unless the link is opened.`,
      html: shell(
        `<h2 style="margin:0 0 12px 0;color:#fff;font-size:20px;">Is this you?</h2>
<p>Someone asked to use this email address for a NWisp account.</p>
<p>A separate message with a confirmation link will follow. If you don't recognise this, ignore both messages &mdash; nothing changes unless that link is opened.</p>`,
      ),
    });

    return Response.json({ ok: true });
  } catch (err) {
    return Response.json({ error: String(err) }, { status: 401 });
  }
});
