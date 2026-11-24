-- TeleStar: права и Row Level Security

-- 1. Сначала забираем все права по умолчанию (Supabase выдаёт их anon/authenticated автоматически)
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- 2. Включаем RLS везде
alter table public.users               enable row level security;
alter table public.bot_contacts        enable row level security;
alter table public.revoked_identifiers enable row level security;
alter table public.login_codes         enable row level security;
alter table public.user_sessions       enable row level security;
alter table public.chats               enable row level security;
alter table public.chat_members        enable row level security;
alter table public.messages            enable row level security;
alter table public.message_reads       enable row level security;
alter table public.user_settings       enable row level security;
alter table public.admin_logs          enable row level security;

-- 3. Политики (таблицы без политик недоступны клиентам: login_codes, user_sessions,
--    admin_logs, bot_contacts, revoked_identifiers)
drop policy if exists users_select_own on public.users;
create policy users_select_own on public.users for select to authenticated
  using (id = public.current_user_id());

drop policy if exists chats_select on public.chats;
create policy chats_select on public.chats for select to authenticated
  using (public.is_chat_member(id));

drop policy if exists chat_members_select on public.chat_members;
create policy chat_members_select on public.chat_members for select to authenticated
  using (public.is_chat_member(chat_id));

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated
  using (public.is_chat_member(chat_id));

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = public.current_user_id() and public.is_chat_member(chat_id));
-- UPDATE/DELETE политик нет: удаление только через RPC delete_message (свои сообщения)

drop policy if exists message_reads_select on public.message_reads;
create policy message_reads_select on public.message_reads for select to authenticated
  using (public.is_chat_member(chat_id));

drop policy if exists user_settings_select on public.user_settings;
create policy user_settings_select on public.user_settings for select to authenticated
  using (user_id = public.current_user_id());

-- 4. Права на таблицы. telegram_id клиенту НЕ отдаётся (колоночные права).
grant select (id, username, display_name, avatar_url, login_identifier, is_banned, created_at) on public.users to authenticated;
grant select on public.chats, public.chat_members, public.message_reads, public.user_settings to authenticated;
grant select on public.messages to authenticated;
grant insert (chat_id, sender_id, content, message_type, file_path, file_name, file_size, file_mime, reply_to)
  on public.messages to authenticated;

-- 5. Права на функции
grant execute on function public.current_user_id(), public.is_chat_member(uuid), public.storage_chat_access(text)
  to authenticated;
grant execute on function
  public.get_chat_list(), public.get_chat_messages(uuid, timestamptz, int), public.create_direct_chat(uuid),
  public.mark_chat_read(uuid), public.delete_message(uuid), public.search_users(text),
  public.update_profile(text, text, boolean), public.get_my_settings(),
  public.update_settings(boolean, boolean, boolean), public.touch_presence()
  to authenticated;

-- Серверные функции — только service_role (ключ хранится на сервере, не в APK)
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant usage on schema public to service_role;
    grant execute on all functions in schema public to service_role;
  end if;
end $$;

-- 6. Realtime
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.messages;      exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.message_reads; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.chat_members;  exception when duplicate_object then null; end;
  end if;
end $$;
alter table public.messages      replica identity full;
alter table public.message_reads replica identity full;
