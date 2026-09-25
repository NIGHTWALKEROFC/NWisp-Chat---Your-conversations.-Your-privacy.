// Feature: TOTP two-factor authentication — "Regenerate backup codes"
// in Settings. Invalidates every existing backup code and issues 10
// brand-new ones — for when the old set has been used up, or the person
// is worried an old copy of them leaked. Requires a valid current code
// (or one of the still-unused old backup codes) first, same reasoning
// as totp-disable/index.ts's own comment: being signed in alone isn't
// enough to prove you hold the second factor.
//
// Authenticated (Firebase ID token in `Authorization: Bearer ...`).
//
// SINGLE-FILE VERSION — see totp-enroll-start/index.ts's own comment.
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
// TOTP (RFC 6238) verification
// ==========================================================================
async function hotp(secretBytes: Uint8Array, counter: number): Promise<string> {
  const counterBytes = new Uint8Array(8);
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
const BACKUP_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
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
// Lockout schedule (shared with totp-verify-login / totp-disable)
// ==========================================================================
const MAX_ATTEMPTS_BEFORE_LOCK = 5;
const LOCK_SCHEDULE_SECONDS = [5 * 60, 30 * 60, 2 * 60 * 60];

function lockSecondsFor(failedAttempts: number): number {
  const tier = Math.min(Math.floor(failedAttempts / MAX_ATTEMPTS_BEFORE_LOCK) - 1, LOCK_SCHEDULE_SECONDS.length - 1);
  return LOCK_SCHEDULE_SECONDS[Math.max(tier, 0)];
}

function describeWait(seconds: number): string {
  if (seconds < 3600) return `${Math.ceil(seconds / 60)} minutes`;
  return `${Math.ceil(seconds / 3600)} hours`;
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
    const body = await req.json();
    const code = typeof body?.code === "string" ? body.code.trim() : null;
    const backupCode = typeof body?.backupCode === "string" ? body.backupCode.trim() : null;
    if (!code && !backupCode) {
      return reply({ error: "Enter your current 2FA code or a backup code first." }, 400);
    }

    const { data: row } = await supabase
      .from("user_totp")
      .select("secret_encrypted, enabled, failed_attempts, locked_until")
      .eq("uid", uid)
      .maybeSingle();

    if (!row || row.enabled !== true) {
      return reply({ error: "Two-factor authentication is not currently on." }, 400);
    }

    if (row.locked_until) {
      const until = new Date(row.locked_until).getTime();
      if (until > Date.now()) {
        return reply(
          { error: `Too many incorrect codes. Please try again in ${describeWait(Math.ceil((until - Date.now()) / 1000))}.` },
          429,
        );
      }
    }

    let valid = false;
    let matchedBackupCodeId: string | null = null;
    if (code) {
      const secretBytes = await decryptSecret(row.secret_encrypted);
      valid = await verifyTotpCode(secretBytes, code);
    } else if (backupCode) {
      const hash = await hashBackupCode(backupCode, uid);
      const { data: match } = await supabase
        .from("user_totp_backup_codes")
        .select("id")
        .eq("uid", uid)
        .eq("code_hash", hash)
        .maybeSingle();
      if (match) {
        valid = true;
        matchedBackupCodeId = match.id;
      }
    }

    if (!valid) {
      const newFailedAttempts = (row.failed_attempts ?? 0) + 1;
      const patch: Record<string, unknown> = { failed_attempts: newFailedAttempts };
      if (newFailedAttempts % MAX_ATTEMPTS_BEFORE_LOCK === 0) {
        patch.locked_until = new Date(Date.now() + lockSecondsFor(newFailedAttempts) * 1000).toISOString();
      }
      await supabase.from("user_totp").update(patch).eq("uid", uid);
      return reply({ error: backupCode ? "That backup code isn't valid." : "Incorrect code. Please try again." }, 400);
    }

    await supabase.from("user_totp").update({ failed_attempts: 0, locked_until: null }).eq("uid", uid);

    // Wipe EVERY existing backup code (including the one just used to
    // authorize this, if any — matchedBackupCodeId is about to be gone
    // along with the rest) and issue a completely fresh set of 10.
    void matchedBackupCodeId; // the blanket delete below covers it too
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

    return reply({ backupCodes });
  } catch (err) {
    return reply({ error: "Could not regenerate backup codes. Please try again." }, 500);
  }
});
