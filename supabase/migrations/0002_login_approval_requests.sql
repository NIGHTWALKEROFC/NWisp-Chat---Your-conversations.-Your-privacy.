-- Feature: new-login accept/deny flow (opt-in, default OFF — see
-- AccountSecurityScreen's "Require approval for new logins" toggle).
--
-- The actual pending-approval request lives in Firestore (see
-- DeviceSessionService.createLoginApprovalRequest) — that's the source
-- of truth both devices read/write. This table exists for ONE reason:
-- Supabase Database Webhooks only fire off Postgres table changes, not
-- Firestore changes, and this app deliberately avoids Firebase Cloud
-- Functions (they require a Blaze billing account). Inserting a tiny row
-- here is just a trigger — a way to get a Database Webhook to fire and
-- call send-login-approval-push, which is what actually notifies the
-- OLD/active device. Nothing here is ever read back by the app.
--
-- Apply this with `supabase db push`, or paste it into the Supabase
-- dashboard's SQL Editor and run it once — same as the rate-limit
-- migration (0001_message_relay_rate_limit.sql).

create table if not exists login_approval_requests (
  id uuid primary key default gen_random_uuid(),
  uid text not null,
  request_id text not null,
  device_label text,
  location text,
  created_at timestamptz not null default now()
);

-- No RLS policy needed beyond "the app's anon key can insert" — same
-- trust level message_relay already has (see that table's own setup).
-- There's no sensitive content here: just a device label and a rough
-- city, already shown to the account owner's own other device anyway.
alter table login_approval_requests enable row level security;

drop policy if exists "anyone can insert login approval pings" on login_approval_requests;
create policy "anyone can insert login approval pings"
  on login_approval_requests for insert
  with check (true);
