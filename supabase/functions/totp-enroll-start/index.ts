// Feature: TOTP two-factor authentication — Settings > Account security >
// "Two-factor authentication" > Enable calls this first. Generates a
// brand-new random TOTP secret, stores it (AES-GCM encrypted) as a
// PENDING row (enabled=false), and returns everything needed to render
// the QR code / manual-entry text in the app (see
// mobile/lib/screens/settings/totp_setup_screen.dart). Nothing is
// actually protected by this secret yet — that only happens once
// totp-enroll-confirm verifies a real code generated from it.
//
// Authenticated (Firebase ID token in `Authorization: Bearer ...`) — the
// app already knows who's asking, no separate identifier needed.
//
// Deliberately refuses to run if this account already has 2FA ON: if it
// didn't, someone who only has your PASSWORD (not your authenticator
// app) could sign in, call this function themselves with their own
// device's valid Firebase session, generate a NEW secret, "confirm" it
// with a code THEY compute (since they're the one who received the
// secret), and silently take over your 2FA — locking you out while
// looking, to them, like a normal "change authenticator" flow. Requiring
// 2FA to be turned OFF first (which itself requires the CURRENT code —
// see totp-disable) closes that gap.
//
// SINGLE-FILE VERSION — no "../_shared/..." imports, so this deploys
// from the Supabase dashboard's online editor as well as the CLI (see
// send-password-reset/index.ts's own comment for why that matters).
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

async function verifyIdToken(req: Request): Promise<{ uid: string; email: string | null }> {
  const authHeader = req.headers.get("Authorization") || "";
  const idToken = authHeader.replace("Bearer ", "");
  if (!idToken) throw new Error("Missing Authorization header");
  const { payload } = await jose.jwtVerify(idToken, JWKS, {
    issuer: `https://securetoken.google.com/${FIREBASE_PROJECT_ID}`,
    audience: FIREBASE_PROJECT_ID,
  });
  return { uid: payload.sub as string, email: (payload.email as string | undefined) ?? null };
}

// ==========================================================================
// AES-GCM secret encryption (TOTP_ENCRYPTION_KEY must be a base64-encoded
// 32-byte key — see the setup doc for how to generate one)
// ==========================================================================
const TOTP_ENCRYPTION_KEY_B64 = Deno.env.get("TOTP_ENCRYPTION_KEY")!;

function b64ToBytes(b64: string): Uint8Array {
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}
function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}

async function encryptionKey(): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", b64ToBytes(TOTP_ENCRYPTION_KEY_B64), { name: "AES-GCM" }, false, [
    "encrypt",
  ]);
}

async function encryptSecret(secretBytes: Uint8Array): Promise<string> {
  const key = await encryptionKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, secretBytes);
  return `${bytesToB64(iv)}:${bytesToB64(new Uint8Array(ciphertext))}`;
}

// ==========================================================================
// Base32 (RFC 4648, no padding) — what authenticator apps expect
// ==========================================================================
const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

function base32Encode(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let output = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += BASE32_ALPHABET[(value << (5 - bits)) & 31];
  return output;
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
    const { uid, email } = await verifyIdToken(req);

    const { data: existing } = await supabase
      .from("user_totp")
      .select("enabled")
      .eq("uid", uid)
      .maybeSingle();

    if (existing?.enabled === true) {
      return reply(
        { error: "Two-factor authentication is already on for this account. Turn it off before setting up a new authenticator." },
        400,
      );
    }

    // 20 random bytes = 160 bits, the standard TOTP secret size.
    const secretBytes = crypto.getRandomValues(new Uint8Array(20));
    const base32Secret = base32Encode(secretBytes);
    const secretEncrypted = await encryptSecret(secretBytes);

    const { error } = await supabase.from("user_totp").upsert({
      uid,
      secret_encrypted: secretEncrypted,
      enabled: false,
      created_at: new Date().toISOString(),
      enabled_at: null,
      failed_attempts: 0,
      locked_until: null,
    });
    if (error) throw error;

    const label = encodeURIComponent(`NWisp:${email ?? uid}`);
    const otpauthUri = `otpauth://totp/${label}?secret=${base32Secret}&issuer=NWisp&algorithm=SHA1&digits=6&period=30`;

    return reply({ secret: base32Secret, otpauthUri });
  } catch (err) {
    return reply({ error: "Could not start two-factor setup. Please try again." }, 500);
  }
});
