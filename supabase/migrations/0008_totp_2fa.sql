-- Feature: TOTP two-factor authentication + one-time backup codes.
--
-- Both tables are ONLY ever written by the new Edge Functions
-- (totp-enroll-start, totp-enroll-confirm, totp-verify-login,
-- totp-disable, totp-regenerate-backup-codes), always with the
-- service-role key, which bypasses RLS — same pattern as
-- 0003_email_otp_and_password_reset.sql. RLS is enabled with NO
-- policies below, so a stray client-side call using the public anon
-- key can't read or write these directly.
--
-- Keyed by Firebase uid (not email) since these functions are all
-- called by an ALREADY-signed-in Firebase user (the app sends the
-- Firebase ID token; the function verifies it and reads the uid out
-- of it) — see each function's own comments.

-- One row per account that has ever started TOTP setup.
-- secret_encrypted: the TOTP secret (raw bytes, base32-able), encrypted
-- with AES-GCM using the TOTP_ENCRYPTION_KEY Edge Function secret —
-- never stored in plaintext at rest. Format: base64(iv) || ":" ||
-- base64(ciphertext) — see totp-enroll-start's encryptSecret().
-- enabled=false while the person is mid-setup (secret generated, QR
-- shown, but the confirmation code hasn't been entered yet); flips to
-- true only once totp-enroll-confirm verifies a real code against it.
-- A never-confirmed pending row is harmless — it's just overwritten if
-- they start setup again, and login never checks `enabled=false` rows.
--
-- failed_attempts / locked_until: brute-force throttle for
-- totp-verify-login/totp-disable/totp-regenerate-backup-codes — 5 wrong
-- codes in a row locks further attempts out for a growing cooldown (see
-- those functions' own comments for the exact schedule). Reset to 0 /
-- null on any correct code.
create table if not exists user_totp (
  uid text primary key,
  secret_encrypted text not null,
  enabled boolean not null default false,
  created_at timestamptz not null default now(),
  enabled_at timestamptz,
  failed_attempts int not null default 0,
  locked_until timestamptz
);
alter table user_totp enable row level security;

-- One row per still-unused backup code. Codes are single-use: consumed
-- rows are deleted outright (not just flagged) so the table only ever
-- holds codes that still work, keeping totp-verify-login's lookup a
-- plain equality check with no extra "not used yet" filtering logic.
-- Regenerating (totp-regenerate-backup-codes) deletes every existing
-- row for that uid and inserts a fresh set of 10.
create table if not exists user_totp_backup_codes (
  id uuid primary key default gen_random_uuid(),
  uid text not null,
  code_hash text not null,
  created_at timestamptz not null default now()
);
alter table user_totp_backup_codes enable row level security;
create index if not exists user_totp_backup_codes_uid_idx on user_totp_backup_codes (uid);
