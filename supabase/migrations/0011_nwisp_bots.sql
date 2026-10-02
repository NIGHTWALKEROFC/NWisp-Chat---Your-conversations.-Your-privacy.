-- Feature: NWisp Bots (Telegram-bot style).
--
-- Paste this whole file into Supabase Dashboard > SQL Editor > New query > Run.
-- It only creates new tables; it doesn't touch anything that already exists.
--
-- Row Level Security is switched ON with NO policies on purpose: nobody can
-- read or write these tables with the public key. Only the two Edge
-- Functions (nwisp-bot-manage and nwisp-bot-api) can, because they use the
-- server-side service key, and they check who is asking before doing
-- anything.

create table if not exists public.bots (
  username      text primary key,              -- lowercase, always ends in _bot
  bot_id        bigint generated always as identity unique,
  owner_uid     text not null,
  name          text not null,
  description   text not null default '',
  photo_data    text,                          -- small data: URL, optional
  rules         jsonb not null default '{}'::jsonb,
  commands      jsonb not null default '[]'::jsonb,
  webhook_url   text,
  webhook_secret text,
  update_cursor bigint not null default 0,      -- last update the bot has acknowledged (like Telegram's offset)
  token_hash    text not null,                 -- SHA-256 of the API token; the token itself is never stored
  created_at    timestamptz not null default now(),
  constraint bots_username_format check (username ~ '^[a-z0-9]([a-z0-9_]*[a-z0-9])?_bot$' and username !~ '__bot$')
);
create index if not exists bots_owner_idx on public.bots (owner_uid);

create table if not exists public.bot_messages (
  id          bigint generated always as identity primary key,
  bot         text not null references public.bots(username) on delete cascade,
  user_uid    text not null,
  direction   text not null check (direction in ('in', 'out')),  -- in = user -> bot, out = bot -> user
  kind        text not null default 'text',                      -- text | photo | callback
  body        text not null default '',
  extra       jsonb not null default '{}'::jsonb,                -- buttons, photo url, callback data, user name
  edited      boolean not null default false,
  deleted     boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists bot_messages_bot_idx  on public.bot_messages (bot, direction, id);
create index if not exists bot_messages_user_idx on public.bot_messages (user_uid, bot, id);

-- Which people have started which bot (the bot may only message people who did).
create table if not exists public.bot_users (
  bot        text not null references public.bots(username) on delete cascade,
  user_uid   text not null,
  chat_id    bigint generated always as identity unique,   -- what the bot sees as the chat id
  blocked    boolean not null default false,
  typing_until timestamptz,
  started_at timestamptz not null default now(),
  primary key (bot, user_uid)
);

alter table public.bots          enable row level security;
alter table public.bot_messages  enable row level security;
alter table public.bot_users     enable row level security;
