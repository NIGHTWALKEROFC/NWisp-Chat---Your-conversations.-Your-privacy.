-- SECURITY AUDIT FINDING (2026-09-24) — please read before applying.
--
-- message_relay was created directly in the Supabase dashboard's table
-- editor (see 0001_message_relay_rate_limit.sql's own comment: "Assumes
-- message_relay has a created_at timestamptz default now() column, which
-- is Supabase's default for a table created via the dashboard's table
-- editor"). Whatever Row Level Security policy it has today — if any —
-- was therefore ALSO set up by hand in the dashboard at some point and
-- was never captured in a tracked migration, so there is no way to
-- audit it from this repo alone.
--
-- THE DEEPER ISSUE THIS POLICY DEPENDS ON, discovered while auditing this:
-- this app has NEVER called Supabase's own auth.signIn — it uses Firebase
-- Auth as its one real identity system, and every Supabase request used
-- to go out under the bare anon key with no Supabase-side session at
-- all. That means Postgres's auth.uid() — what every policy below
-- checks — was ALWAYS null on every request, for every user, no matter
-- what policy text existed. A policy comparing auth.uid() to a column
-- can only ever have been silently failing (blocking everything) or
-- there was no real per-user policy at all (fully open behind the
-- shared, non-secret anon key) — there is no third option.
--
-- This is fixed on the app side in mobile/lib/main.dart, using Supabase's
-- documented "Third-Party Auth" support for Firebase: the Supabase client
-- now sends each signed-in person's Firebase ID token instead of the bare
-- anon key, which is what lets auth.uid() below finally resolve to their
-- real Firebase uid. Full official guide:
-- https://supabase.com/docs/guides/auth/third-party/firebase-auth
--
-- THIS MIGRATION DOES NOTHING USEFUL ON ITS OWN — two more steps, done
-- once, in the Supabase dashboard, are what actually activate it:
--   1. Authentication > Third-Party Auth > add an integration for this
--      app's Firebase project (you'll need the Project ID from the
--      Firebase Console's Project Settings). Supabase then only accepts
--      ID tokens from that specific Firebase project — a token from any
--      other Firebase project is rejected before it reaches your
--      database, so registering the right project ID matters.
--   2. Every Firebase user needs Supabase's required `role: 'authenticated'`
--      custom claim set on their account (this is what the official guide
--      calls "Assign the role: 'authenticated' custom user claim to all
--      your users"). That claim can only be set with the Firebase Admin
--      SDK, from a privileged backend holding a Firebase service account
--      key — client code can never set its own claims, by design. This
--      app deliberately has no Firebase Cloud Functions (see
--      0002_login_approval_requests.sql's comment on why — Blaze billing)
--      and does NOT yet have a Supabase Edge Function that does this
--      either. Until one exists, newly-issued Firebase ID tokens won't
--      carry that claim, Supabase's gateway may not treat them as fully
--      authenticated, and auth.uid() may still come through as null —
--      meaning the policies below would (safely) block real users rather
--      than let anyone through incorrectly, but messaging would not work
--      until this piece is built. Flagged here rather than built blind:
--      it means securely storing a Firebase service account key as an
--      Edge Function secret and getting Google's OAuth2 service-account
--      token flow right, which deserves its own focused pass rather than
--      being rushed alongside everything else in this audit.
--
-- Why any of this matters even though message CONTENT is safe either
-- way: every row's `ciphertext` is end-to-end encrypted client-side (see
-- SignalSessionService) before it's ever sent to Supabase, so even a
-- fully open table could not expose what anyone actually wrote. What IS
-- at risk without correct RLS is METADATA — sender_uid, recipient_uid,
-- conversation_id, message_type (text/image/video/voice/reaction/
-- receipt/edit/delete/...), and created_at are all plain (unencrypted)
-- columns, because Supabase's own routing needs sender/recipient, and
-- the app's rate limiter needs sender_uid + message_type + created_at
-- (see 0001). Without this fixed, any authenticated Supabase client —
-- not just this app — could query this table directly (bypassing the
-- app's own `.eq('recipient_uid', _myUid)` filter in
-- MessageRelayService._catchUp, which is a CLIENT-SIDE convenience, not
-- a security boundary on its own) and see who is messaging whom, how
-- often, and what kind of message, for every user — a real metadata/
-- traffic-analysis privacy leak, even with content fully protected.
--
-- ONE MORE DASHBOARD CHECK, independent of all of the above: Table
-- Editor > message_relay > confirm "Enable RLS" is ON. If a table has
-- RLS policies but RLS itself is toggled off, every policy — old ones
-- and the ones this file creates — is silently ignored and the table is
-- fully open. This is a common, easy-to-miss Supabase default for a
-- table created via the dashboard's table editor, which is exactly how
-- this one was made.
--
-- Apply this with `supabase db push`, or paste it into the dashboard's
-- SQL Editor and run it once — same as every other migration in this
-- folder.
--
-- ORDERING WARNING — read this part even if you skip everything above:
-- do NOT apply this to a live/production database until the Third-Party
-- Auth integration AND the role: 'authenticated' claim piece (both
-- described above) are confirmed actually working end to end. Once
-- applied, EVERY request's auth.uid() must resolve correctly for
-- messaging to keep working at all — if it's still null for real users
-- at that point, this doesn't fail open (it was never open to begin
-- with in the way that matters), it fails CLOSED: every send, receive,
-- and cleanup delete on message_relay stops working for everyone,
-- immediately, app-wide. Test on a staging project or with one test
-- account first if at all possible.

alter table message_relay enable row level security;

-- Read: only the intended recipient can see a row at all. This is what
-- actually enforces MessageRelayService._catchUp's `.eq('recipient_uid',
-- _myUid)` — that client-side filter alone is not a security boundary;
-- this policy is.
drop policy if exists "message_relay recipient can read" on message_relay;
create policy "message_relay recipient can read"
  on message_relay for select
  using (auth.uid()::text = recipient_uid);

-- Insert: you can only ever send AS yourself — stops one account from
-- forging sender_uid to impersonate someone else in another person's
-- inbox (the message itself would still fail to decrypt against a real
-- session, but a forged sender_uid could still be used to spam or
-- confuse someone with a believable-looking sender).
drop policy if exists "message_relay sender can insert" on message_relay;
create policy "message_relay sender can insert"
  on message_relay for insert
  with check (auth.uid()::text = sender_uid);

-- Delete: the recipient deletes a row once they've processed it (see
-- MessageRelayService._handleRow's cleanup), and a sender can also
-- delete their own sent-but-not-yet-delivered rows — needed for account
-- deletion cleanup (see AccountLifecycleService, which deletes by both
-- sender_uid and recipient_uid). Nobody can delete a row that is neither
-- to nor from them.
drop policy if exists "message_relay recipient or sender can delete" on message_relay;
create policy "message_relay recipient or sender can delete"
  on message_relay for delete
  using (auth.uid()::text = recipient_uid or auth.uid()::text = sender_uid);

-- No update policy: nothing in the app ever updates a message_relay row
-- in place (an edited message is a new encrypted payload sent as a fresh
-- row with message_type 'edit' — see MessageRelayService.sendEditedText),
-- so update is left with no policy at all, which means it's fully
-- denied. That is intentional, not an oversight: a row nobody can update
-- can't be tampered with in transit, only replaced by a brand-new insert
-- that has to pass the insert policy above.
