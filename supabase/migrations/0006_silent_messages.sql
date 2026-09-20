-- Feature: "Send silently". The sender can choose to send a message that
-- doesn't trigger a push notification on the recipient's phone (it still
-- arrives, and still counts as unread — it just doesn't buzz).
--
-- This adds one plain boolean column to the relay table. It has to be a real
-- column (not part of the end-to-end-encrypted message) because the
-- `send-push` Edge Function reads it to decide whether to notify — and that
-- function, by design, can never see message contents. The flag reveals only
-- "this message shouldn't ping", nothing about what it says.
--
-- Apply once: paste into Supabase Dashboard > SQL Editor > Run
-- (or `supabase db push`). Safe to run more than once. Ordinary messages are
-- unaffected: the app only sends the column for silent messages, and the
-- default is false. Until this is run, only "Send silently" fails (with a
-- message saying so); everything else keeps working.

alter table message_relay
  add column if not exists silent boolean not null default false;
