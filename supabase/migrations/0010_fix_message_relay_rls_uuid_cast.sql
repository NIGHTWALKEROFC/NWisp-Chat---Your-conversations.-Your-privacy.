-- BUG FIX (2026-09-26) — "Still couldn't send — PostgrestException(message:
-- invalid input syntax for type uuid: "X54itkVt9Vgp4nr6ZBXzYhjS2pe2", code:
-- 22P02, ...)" on every 1:1 send AND every group send/resend.
--
-- ROOT CAUSE:
-- Supabase's built-in auth.uid() function is defined (inside Supabase's own
-- internals, not something this project wrote) roughly as:
--
--   select nullif(current_setting('request.jwt.claims', true), '')::json->>'sub' ... )::uuid
--
-- Notice the trailing `::uuid` cast. That cast assumes the JWT's "sub" claim
-- is always a real UUID — true for Supabase's own built-in auth, but this
-- app uses Firebase Auth as its identity system (see
-- 0009_message_relay_rls.sql and mobile/lib/main.dart's Third-Party Auth
-- setup). A Firebase uid looks like "X54itkVt9Vgp4nr6ZBXzYhjS2pe2" — 28
-- base62 characters, NOT a UUID. So the moment any policy below calls
-- auth.uid(), Postgres tries to cast that Firebase uid to type uuid,
-- fails, and raises exactly the error in the screenshot (Postgres error
-- code 22P02 = invalid_text_representation) — before the insert/select/
-- delete itself ever runs.
--
-- This hits EVERY message_relay operation that goes through
-- insertMessageRelayRow (see mobile/lib/services/message_relay_service.dart)
-- because the INSERT policy from 0009_message_relay_rls.sql evaluates
-- `auth.uid()::text = sender_uid` on every insert. That's why it wasn't
-- just 1:1 chat — GroupMessageRelayService.sendGroupMessage /
-- resendTextMessage / retryPendingResends all call the exact same
-- insertMessageRelayRow helper, so a group send hits the identical crash
-- and immediately shows the "Resend" action, because the failed insert
-- looks to the app like any other failed send.
--
-- THE FIX:
-- Read the JWT's "sub" claim directly as TEXT via auth.jwt(), which
-- returns the whole token as jsonb and never casts anything to uuid.
-- `auth.jwt() ->> 'sub'` gives the exact same Firebase uid string
-- auth.uid() was trying (and failing) to hand back, just without the
-- uuid cast in the way. Every column being compared against it
-- (sender_uid, recipient_uid) is already `text`, so this is a straight,
-- safe swap — no column types change, no app-side code changes needed.
--
-- Apply this with `supabase db push`, or paste it into the Supabase
-- dashboard's SQL Editor and run it once, exactly like every other
-- migration in this folder. Safe to run more than once (each policy is
-- dropped and recreated).

drop policy if exists "message_relay recipient can read" on message_relay;
create policy "message_relay recipient can read"
  on message_relay for select
  using ((select auth.jwt() ->> 'sub') = recipient_uid);

drop policy if exists "message_relay sender can insert" on message_relay;
create policy "message_relay sender can insert"
  on message_relay for insert
  with check ((select auth.jwt() ->> 'sub') = sender_uid);

drop policy if exists "message_relay recipient or sender can delete" on message_relay;
create policy "message_relay recipient or sender can delete"
  on message_relay for delete
  using ((select auth.jwt() ->> 'sub') = recipient_uid or (select auth.jwt() ->> 'sub') = sender_uid);

-- No update policy, same as before — nothing in the app ever updates a
-- message_relay row in place (see 0009_message_relay_rls.sql's own note),
-- so update stays fully denied.
