-- Feature: Instagram-style email verification (OTP code) for signup, and
-- a branded button-based password reset — see EMAIL_SETUP.md for the full
-- picture. These three tables are ONLY ever written by the new Edge
-- Functions (send-signup-otp, verify-signup-otp, confirm-verified-email,
-- send-password-reset), always with the service-role key, which bypasses
-- RLS the same way get-signed-url's Postgres calls already do. RLS is
-- still enabled with NO policies below, so a stray client-side call using
-- the public anon key can't read or write these directly — matching the
-- "can't be bypassed by calling Supabase directly" spirit of
-- 0001_message_relay_rate_limit.sql.

-- One row per email currently mid-verification (signup OTP flow, and also
-- reused for the "confirm it's really you" step nothing else needs — see
-- send-signup-otp/index.ts). Keyed by lowercased email rather than uid,
-- because this step happens BEFORE the Firebase Auth account exists.
create table if not exists email_otps (
  email text primary key,
  code_hash text not null,
  attempts int not null default 0,
  expires_at timestamptz not null,
  last_sent_at timestamptz not null default now()
);
alter table email_otps enable row level security;

-- Set by verify-signup-otp once the code above is confirmed correct;
-- read (and consumed) once by confirm-verified-email right after the
-- Firebase Auth account is actually created, closing the loop between
-- "we verified this email" and "this specific new account owns it".
create table if not exists verified_emails (
  email text primary key,
  verified_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed boolean not null default false
);
alter table verified_emails enable row level security;

-- Simple request log for password-reset rate limiting (see
-- send-password-reset/index.ts, which counts rows from the last hour
-- before deciding whether to actually send another email) — protects
-- both the person's inbox and this project's Gmail sending quota from
-- someone hammering the same email address.
create table if not exists password_reset_requests (
  id bigint generated always as identity primary key,
  email text not null,
  requested_at timestamptz not null default now()
);
alter table password_reset_requests enable row level security;
create index if not exists password_reset_requests_email_idx
  on password_reset_requests (email, requested_at);
