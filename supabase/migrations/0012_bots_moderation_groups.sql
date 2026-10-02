-- Feature: bot report & ban tools, bots in groups, command menus.
--
-- Paste this whole file into Supabase Dashboard > SQL Editor > New query > Run.
-- Run 0011_nwisp_bots.sql first. This only ADDS columns and tables; nothing is
-- removed or changed. Safe to run twice.

-- ---- moderation ---------------------------------------------------------
alter table public.bots add column if not exists status text not null default 'active';
alter table public.bots add column if not exists status_reason text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bots_status_check') then
    alter table public.bots add constraint bots_status_check check (status in ('active', 'suspended', 'banned'));
  end if;
end $$;

create table if not exists public.bot_reports (
  id           bigint generated always as identity primary key,
  bot          text not null references public.bots(username) on delete cascade,
  reporter_uid text not null,
  reason       text not null,
  details      text not null default '',
  dismissed    boolean not null default false,
  created_at   timestamptz not null default now(),
  unique (bot, reporter_uid)          -- one report per person per bot
);
create index if not exists bot_reports_open_idx on public.bot_reports (dismissed, bot);

-- A bot's owner can block one person from their bot (Bot API: blockUser).
alter table public.bot_users add column if not exists owner_blocked boolean not null default false;
-- false = the person only talked to the bot inside a group, so the bot may not message them privately.
alter table public.bot_users add column if not exists started_private boolean not null default true;

-- ---- bots in groups -----------------------------------------------------
create table if not exists public.bot_groups (
  bot        text not null references public.bots(username) on delete cascade,
  group_id   text not null,
  group_name text not null default '',
  added_by   text not null,
  chat_id    bigint generated always as identity unique,   -- the bot sees the group as -chat_id
  added_at   timestamptz not null default now(),
  primary key (bot, group_id)
);

alter table public.bot_messages add column if not exists group_id text;
alter table public.bot_messages add column if not exists visible_to_bot boolean not null default true;
alter table public.bot_messages alter column user_uid set default '';
create index if not exists bot_messages_group_idx on public.bot_messages (bot, group_id, id);

alter table public.bot_reports enable row level security;
alter table public.bot_groups  enable row level security;
