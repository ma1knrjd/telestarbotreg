-- TeleStar: схема базы данных
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ===== Пользователи =====
create table if not exists public.users (
  id               uuid primary key default gen_random_uuid(),
  telegram_id      bigint unique,                 -- NULL после /unlink
  username         text,                          -- Telegram @username (без @)
  display_name     text not null,
  avatar_url       text,
  login_identifier text unique,                   -- нормализованный, напр. +15552223267
  is_banned        boolean not null default false,
  unlinked_at      timestamptz,
  last_seen_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists users_username_lower_idx on public.users (lower(username));

-- Пользователи, запустившие бота (нужно для /addnumber @username)
create table if not exists public.bot_contacts (
  telegram_id bigint primary key,
  username    text,
  first_name  text,
  last_name   text,
  started_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists bot_contacts_username_idx on public.bot_contacts (lower(username));

-- Отозванные идентификаторы: никогда не выдаются повторно и не принимаются для входа
create table if not exists public.revoked_identifiers (
  identifier text primary key,
  revoked_at timestamptz not null default now(),
  former_user_id uuid
);

-- ===== Авторизация =====
create table if not exists public.login_codes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  code_hash  text not null,                      -- HMAC, открытый код не хранится
  expires_at timestamptz not null,
  attempts   int  not null default 0,
  used       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists login_codes_user_idx on public.login_codes (user_id, created_at desc);

create table if not exists public.user_sessions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.users(id) on delete cascade,
  token_hash text not null unique,               -- хеш refresh-токена
  device     text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index if not exists user_sessions_user_idx on public.user_sessions (user_id);

-- ===== Чаты =====
create table if not exists public.chats (
  id         uuid primary key default gen_random_uuid(),
  type       text not null default 'direct' check (type in ('direct','group')),
  title      text,
  direct_key text unique,                        -- "<minuuid>:<maxuuid>" для личных чатов
  created_by uuid references public.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists public.chat_members (
  id        uuid primary key default gen_random_uuid(),
  chat_id   uuid not null references public.chats(id) on delete cascade,
  user_id   uuid not null references public.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  unique (chat_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members (user_id);

create table if not exists public.messages (
  id           uuid primary key default gen_random_uuid(),
  chat_id      uuid not null references public.chats(id) on delete cascade,
  sender_id    uuid not null references public.users(id) on delete cascade,
  content      text not null default '',
  message_type text not null default 'text' check (message_type in ('text','image','file')),
  file_path    text,
  file_name    text,
  file_size    bigint,
  file_mime    text,
  reply_to     uuid references public.messages(id) on delete set null,
  created_at   timestamptz not null default now(),
  edited_at    timestamptz,
  deleted_at   timestamptz,
  check (char_length(content) <= 4000)
);
create index if not exists messages_chat_created_idx on public.messages (chat_id, created_at desc);

create table if not exists public.message_reads (
  id         uuid primary key default gen_random_uuid(),
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id    uuid not null references public.users(id) on delete cascade,
  chat_id    uuid not null references public.chats(id) on delete cascade,
  read_at    timestamptz not null default now(),
  unique (message_id, user_id)
);
create index if not exists message_reads_chat_idx on public.message_reads (chat_id, user_id);

create table if not exists public.user_settings (
  user_id             uuid primary key references public.users(id) on delete cascade,
  find_by_identifier  boolean not null default true,   -- можно ли найти по ID
  show_last_seen      boolean not null default true,
  notifications       boolean not null default true,
  updated_at          timestamptz not null default now()
);

create table if not exists public.admin_logs (
  id                uuid primary key default gen_random_uuid(),
  admin_telegram_id bigint not null,
  action            text not null,
  target_user_id    uuid,
  details           jsonb,
  created_at        timestamptz not null default now()
);

-- ===== Триггеры =====
create or replace function public.tg_touch_updated() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists users_touch on public.users;
create trigger users_touch before update on public.users for each row execute function public.tg_touch_updated();

-- Время сообщения задаёт сервер; reply_to только из того же чата
create or replace function public.tg_messages_before_insert() returns trigger language plpgsql as $$
begin
  new.created_at := now();
  new.edited_at := null;
  new.deleted_at := null;
  if new.reply_to is not null and not exists
     (select 1 from public.messages m where m.id = new.reply_to and m.chat_id = new.chat_id) then
    raise exception 'reply_to must be in the same chat';
  end if;
  if new.message_type = 'text' and btrim(new.content) = '' then
    raise exception 'empty message';
  end if;
  return new;
end $$;
drop trigger if exists messages_bi on public.messages;
create trigger messages_bi before insert on public.messages for each row execute function public.tg_messages_before_insert();
