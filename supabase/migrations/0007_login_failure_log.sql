-- Feature: failed-login lockout. Two layers, working together:
--
-- 1. Per-device/IP escalating block (uses the `abuse_throttle` table that
--    already exists from 0005_device_abuse_throttle.sql, action =
--    'login_failed') — the SAME device/network that keeps failing gets
--    blocked (1 hour, then 1 day), without affecting the real owner
--    logging in from a different, non-abusing device. No new table needed
--    for this part.
--
-- 2. Per-ACCOUNT failure log (this table) — every failed attempt against
--    a given email is logged here regardless of which device/IP it came
--    from, so Account Security can show "10+ failed attempts recently —
--    consider turning on extra security" even if an attacker is spreading
--    attempts across many different devices/networks specifically to
--    dodge the per-device block above.

create table if not exists login_failure_log (
  id bigint generated always as identity primary key,
  email text not null,
  ip text,
  device_id text,
  created_at timestamptz not null default now()
);
alter table login_failure_log enable row level security;
create index if not exists login_failure_log_email_idx on login_failure_log (email, created_at);
