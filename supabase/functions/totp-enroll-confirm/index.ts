// Feature: TOTP two-factor authentication — step 2 of setup. The app
// calls this right after the person types the 6-digit code their
// authenticator app shows for the secret totp-enroll-start just gave
// them (see mobile/lib/screens/settings/totp_setup_screen.dart). Proves
// they actually scanned/entered the secret correctly (not just that
// they have SOME code) before turning 2FA on for real, and hands back
// 10 one-time backup codes to show ONCE — the app also displays a
// "save these somewhere safe" screen right after (see
// totp_backup_codes_screen.dart), since these are never shown again.
//
// Authenticated (Firebase ID token in `Authorization: Bearer ...`).
//
// SINGLE-FILE VERSION — see totp-enroll-start/index.ts's own comment
// for why (dashboard-editor deploy compatibility).
//
// Secrets it reads:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY,
//   FIREBASE_PROJECT_ID, TOTP_ENCRYPTION_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as jose from "https://esm.sh/jose@5";

// ==========================================================================
// Firebase ID token verification
// ==========================================================================
const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const JWKS = jose.createRemoteJWKSet(
  new URL("https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com"),
);

async function verifyIdToken(req: Request): Promise<{ uid: string }> {
  const authHeader = req.headers.get("Authorization") || "";
  const idToken = authHeader.replace("Bearer ", "");
  if (!idToken) throw new Error("Missing Authorization header");
  const { payload } = await jose.jwtVerify(idToken, JWKS, {
    issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
    audience: FIREBASE_PROJECT_ID,
  });
  return { uid: payload.sub as string };
}

// ==========================================================================
// AES-GCM secret decryption
// ==========================================================================
const TOTP_ENCRYPTION_KEY_B64 = Deno.env.get("TOTP_ENCRYPTION_KEY")!;

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

async function decryptionKey(): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", b64ToBytes(TOTP_ENCRYPTION_KEY_B64), { name: "AES-GCM" }, false, [
    "decrypt",
  ]);
}

async function decryptSecret(stored: string): Promise<Uint8Array> {
  const [ivB64, dataB64] = stored.split(":");
  const key = await decryptionKey();
  const plain = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: b64ToBytes(ivB64) },
    key,
    b64ToBytes(dataB64),
  );
  return new Uint8Array(plain);
}

// ==========================================================================
// TOTP (RFC 6238) verification — HMAC-SHA1, 30s step, 6 digits, ±1 step
// window to tolerate clock drift between the phone and the authenticator.
// ==========================================================================
async function hotp(secretBytes: Uint8Array, counter: number): Promise<string> {
  const counterBytes = new Uint8Array(8);
  // Counter is written big-endian, high 4 bytes always zero at this scale.
  let c = counter;
  for (let i = 7; i >= 0; i--) {
    counterBytes[i] = c & 0xff;
    c = Math.floor(c / 256);
  }
  const key = await crypto.subtle.importKey("raw", secretBytes, { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const hmac = new Uint8Array(await crypto.subtle.sign("HMAC", key, counterBytes));
  const offset = hmac[hmac.length - 1] & 0x0f;
  const binary =
    ((hmac[offset] & 0x7f) << 24) | ((hmac[offset + 1] & 0xff) << 16) | ((hmac[offset + 2] & 0xff) << 8) | (hmac[offset + 3] & 0xff);
  return String(binary % 1_000_000).padStart(6, "0");
}

async function verifyTotpCode(secretBytes: Uint8Array, code: string): Promise<boolean> {
  if (!/^\d{6}$/.test(code)) return false;
  const counter = Math.floor(Date.now() / 1000 / 30);
  for (const drift of [0, -1, 1]) {
    if ((await hotp(secretBytes, counter + drift)) === code) return true;
  }
  return false;
}

// ==========================================================================
// Backup codes
// ==========================================================================
const BACKUP_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O/1/I — easy to read out loud
const BACKUP_CODE_COUNT = 10;

function randomBackupCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  let raw = "";
  for (const b of bytes) raw += BACKUP_CODE_ALPHABET[b % BACKUP_CODE_ALPHABET.length];
  return `${raw.slice(0, 4)}-${raw.slice(4, 8)}`;
}

async function hashBackupCode(code: string, uid: string): Promise<string> {
  const normalized = code.trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
  const data = new TextEncoder().encode(`${uid}:backup:${normalized}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ==========================================================================
// The function
// ==========================================================================
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function reply(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  try {
    const { uid } = await verifyIdToken(req);
    const { code } = await req.json();
    if (typeof code !== "string") {
      return reply({ error: "Enter the 6-digit code from your authenticator app." }, 400);
    }

    const { data: row } = await supabase
      .from("user_totp")
      .select("secret_encrypted, enabled")
      .eq("uid", uid)
      .maybeSingle();

    if (!row) {
      return reply({ error: "Start two-factor setup first." }, 400);
    }
    if (row.enabled === true) {
      return reply({ error: "Two-factor authentication is already on." }, 400);
    }

    const secretBytes = await decryptSecret(row.secret_encrypted);
    const valid = await verifyTotpCode(secretBytes, code.trim());
    if (!valid) {
      return reply({ error: "Incorrect code. Please try again." }, 400);
    }

    const { error: updateError } = await supabase
      .from("user_totp")
      .update({ enabled: true, enabled_at: new Date().toISOString(), failed_attempts: 0, locked_until: null })
      .eq("uid", uid);
    if (updateError) throw updateError;

    // Fresh backup codes — wipe any leftovers from a previous enrollment
    // (there shouldn't be any at this point since disabling 2FA already
    // clears them, but this keeps the table honest either way).
    await supabase.from("user_totp_backup_codes").delete().eq("uid", uid);

    const backupCodes: string[] = [];
    const rows: { uid: string; code_hash: string }[] = [];
    for (let i = 0; i < BACKUP_CODE_COUNT; i++) {
      const plain = randomBackupCode();
      backupCodes.push(plain);
      rows.push({ uid, code_hash: await hashBackupCode(plain, uid) });
    }
    const { error: insertError } = await supabase.from("user_totp_backup_codes").insert(rows);
    if (insertError) throw insertError;

    return reply({ enabled: true, backupCodes });
  } catch (err) {
    return reply({ error: "Could not confirm two-factor setup. Please try again." }, 500);
  }
});
