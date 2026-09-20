-- Feature: device-level abuse throttling, on top of the per-email limits
-- from 0003/0004. Switching WiFi networks changes an IP address, but the
-- app's own persisted device id (DeviceSessionService._localDeviceId, a
-- UUID stored in secure storage on first run) does NOT change just from
-- switching networks -- so tracking both together means "try again on
-- different WiFi" alone no longer resets a block. See each Edge
-- Function's own comments for the honest limit on this (reinstalling
-- the app does still generate a fresh device id -- there's no fully
-- unspoofable identifier without far more invasive device
-- fingerprinting than belongs in this app).

-- Generic escalating throttle, reused across signup_otp, password_reset
-- and (indirectly, via signup_ip_log below) account_creation. `subject`
-- is a tagged value like 'ip:1.2.3.4' or 'device:<uuid>'; `action` keeps
-- the same subject's limits for different actions independent of each
-- other (spamming OTPs doesn't also use up your password-reset
-- allowance).
create table if not exists abuse_throttle (
  subject text not null,
  action text not null,
  count int not null default 0,
  window_started_at timestamptz not null default now(),
  escalation_level int not null default 0,
  blocked_until timestamptz,
  primary key (subject, action)
);
alter table abuse_throttle enable row level security;

-- Extends the existing per-IP account-creation limit (0004) to also
-- match by device id, the same OR-both-dimensions approach as above.
alter table signup_ip_log add column if not exists device_id text;
create index if not exists signup_ip_log_device_idx on signup_ip_log (device_id, created_at);
