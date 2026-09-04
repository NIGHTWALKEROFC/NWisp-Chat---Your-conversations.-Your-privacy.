-- Feature: rate limiting / spam & abuse protection on message_relay.
--
-- Nothing currently stops one account from inserting thousands of rows a
-- second into message_relay straight from the client SDK — there's no
-- Edge Function in that path to gate it. A Postgres trigger is the right
-- place to enforce this: it runs on every insert regardless of which
-- client/SDK made it, so it can't be bypassed by calling Supabase
-- directly instead of going through the app.
--
-- Design notes:
--  * Counts DISTINCT client_id values, not raw rows. A single group
--    message fans out to N rows (one per member) that all share the SAME
--    client_id — counting raw rows would make sending one message to a
--    50-person group look like 50 messages and trip the limit on a
--    single legitimate send. Counting distinct client_id treats that
--    fan-out as the ONE logical message it actually is.
--  * Only counts message_type IN ('text','image','video','voice') — the
--    real abuse vector is flooding someone with message CONTENT.
--    'receipt' and 'edit' rows are exempt: receipts fire automatically
--    (marking 40 messages read at once when opening a busy chat would
--    otherwise trip the same limit as real spam), and edits are already
--    self-limiting (you can only edit your own messages, within a time
--    window).
--  * Threshold (30 messages / 10 seconds per sender) is generous for
--    real use — fast typing, sending several photos in a row — while
--    still blocking a script-driven flood. Adjust the two constants
--    below if you need a different balance.
--
-- Apply this with `supabase db push`, or paste it into the Supabase
-- dashboard's SQL Editor and run it once. Assumes message_relay has a
-- `created_at timestamptz default now()` column, which is Supabase's
-- default for a table created via the dashboard's table editor — if
-- your table uses a different column name for the insert timestamp,
-- change `created_at` below to match.

create or replace function enforce_message_rate_limit()
returns trigger as $$
declare
  distinct_recent_sends integer;
  max_sends_per_window constant integer := 30;
  window_seconds constant integer := 10;
begin
  if new.message_type not in ('text', 'image', 'video', 'voice') then
    return new;
  end if;

  select count(distinct client_id) into distinct_recent_sends
  from message_relay
  where sender_uid = new.sender_uid
    and message_type in ('text', 'image', 'video', 'voice')
    and created_at > now() - (window_seconds || ' seconds')::interval;

  if distinct_recent_sends >= max_sends_per_window then
    raise exception 'Rate limit exceeded: too many messages sent too quickly. Please wait a moment and try again.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$ language plpgsql security definer;

drop trigger if exists message_relay_rate_limit on message_relay;
create trigger message_relay_rate_limit
before insert on message_relay
for each row execute function enforce_message_rate_limit();
