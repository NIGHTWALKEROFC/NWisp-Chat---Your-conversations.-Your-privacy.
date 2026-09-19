-- Feature: signup/OTP/password-reset abuse limits, and OTP-based password
-- reset as an alternative to the emailed link. See EMAIL_SETUP.md and the
-- Edge Functions that read/write these for the full picture. Same
-- RLS-on-no-policies pattern as 0003 -- only the service-role key (used by
-- the Edge Functions) can read or write these; the app's anon key cannot.

-- Escalating spam protection for signup OTP requests: send_count counts
-- sends within the current "cycle"; hitting 3 escalates blocked_until to
-- 1 hour, and hitting the cap again after that escalates it to 1 day.
-- See send-signup-otp/index.ts for the exact logic.
alter table email_otps add column if not exists send_count int not null default 0;
alter table email_otps add column if not exists escalation_level int not null default 0;
alter table email_otps add column if not exists blocked_until timestamptz;

-- One row per completed (not just attempted) account creation, so
-- send-signup-otp can tell how many accounts a given network has
-- actually finished creating recently and block further signups from
-- it. Written by confirm-verified-email, right after an account
-- actually finishes being created -- never by send-signup-otp itself,
-- so someone who requests a code but never finishes signing up doesn't
-- count against this limit.
create table if not exists signup_ip_log (
  id bigint generated always as identity primary key,
  ip text not null,
  created_at timestamptz not null default now()
);
alter table signup_ip_log enable row level security;
create index if not exists signup_ip_log_ip_idx on signup_ip_log (ip, created_at);

-- Separate from email_otps (the signup one) so a signup OTP and a
-- password-reset OTP pending for the same address at the same time
-- can never collide with each other.
create table if not exists password_reset_otps (
  email text primary key,
  code_hash text not null,
  attempts int not null default 0,
  expires_at timestamptz not null,
  last_sent_at timestamptz not null default now()
);
alter table password_reset_otps enable row level security;
