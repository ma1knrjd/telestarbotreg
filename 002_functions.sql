-- TeleStar: функции. Клиентские (authenticated) и серверные (только service_role).

-- ===== Вспомогательные =====
-- Текущий пользователь: JWT валиден, сессия не отозвана, пользователь не заблокирован.
create or replace function public.current_user_id() returns uuid
language sql stable security definer set search_path = public as $$
  select u.id from public.users u
  where u.id = nullif(auth.jwt() ->> 'sub', '')::uuid
    and not u.is_banned
    and u.telegram_id is not null
    and exists (select 1 from public.user_sessions s
                where s.id = nullif(auth.jwt() ->> 'sid', '')::uuid
                  and s.user_id = u.id and s.revoked_at is null and s.expires_at > now());
$$;

create or replace function public.is_chat_member(p_chat uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.chat_members cm
                 where cm.chat_id = p_chat and cm.user_id = public.current_user_id());
$$;

-- Принадлежит ли путь в storage чату пользователя: первый сегмент пути = uuid чата
create or replace function public.storage_chat_access(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
    when split_part(p_name, '/', 1) ~ '^[0-9a-fA-F-]{36}$'
    then public.is_chat_member(split_part(p_name, '/', 1)::uuid)
    else false end;
$$;

create or replace function public.normalize_identifier(p text) returns text
language sql immutable as $$
  select case
    when regexp_replace(coalesce(p,''), '[\s()\-]', '', 'g') ~ '^\+[0-9]{3,15}$'
    then regexp_replace(p, '[\s()\-]', '', 'g') else null end;
$$;

create or replace function public.random_digits(n int) returns text
language plpgsql volatile set search_path = public, extensions as $$
declare b bytea := gen_random_bytes(n); r text := ''; i int;
begin
  for i in 0..n-1 loop r := r || (get_byte(b, i) % 10)::text; end loop;
  return r;
end $$;

create or replace function public.profile_json(p_uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', u.id, 'username', u.username, 'display_name', u.display_name,
    'avatar_url', u.avatar_url,
    'last_seen_at', case when coalesce(s.show_last_seen, true) then u.last_seen_at else null end)
  from public.users u left join public.user_settings s on s.user_id = u.id
  where u.id = p_uid;
$$;

-- ===== Клиентские функции (роль authenticated) =====
create or replace function public.get_chat_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.current_user_id(); res jsonb;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  select coalesce(jsonb_agg(row order by sort_ts desc), '[]'::jsonb) into res from (
    select
      jsonb_build_object(
        'chat_id', c.id, 'type', c.type, 'title', c.title,
        'peer', (select public.profile_json(cm2.user_id) from public.chat_members cm2
                 where cm2.chat_id = c.id and cm2.user_id <> me limit 1),
        'last_message', (select jsonb_build_object('id', m.id, 'content', m.content,
                           'message_type', m.message_type, 'sender_id', m.sender_id,
                           'created_at', m.created_at, 'deleted', m.deleted_at is not null)
                         from public.messages m where m.chat_id = c.id
                         order by m.created_at desc limit 1),
        'unread', (select count(*) from public.messages m
                   where m.chat_id = c.id and m.sender_id <> me and m.deleted_at is null
                     and not exists (select 1 from public.message_reads r
                                     where r.message_id = m.id and r.user_id = me))
      ) as row,
      coalesce((select max(m.created_at) from public.messages m where m.chat_id = c.id), c.created_at) as sort_ts
    from public.chats c join public.chat_members cm on cm.chat_id = c.id and cm.user_id = me
  ) t;
  return res;
end $$;

create or replace function public.get_chat_messages(p_chat uuid, p_before timestamptz default null, p_limit int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.current_user_id(); res jsonb;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.is_chat_member(p_chat) then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(x.j order by x.created_at desc), '[]'::jsonb) into res from (
    select m.created_at,
      jsonb_build_object(
        'id', m.id, 'chat_id', m.chat_id, 'sender_id', m.sender_id,
        'content', m.content, 'message_type', m.message_type,
        'file_path', m.file_path, 'file_name', m.file_name, 'file_size', m.file_size, 'file_mime', m.file_mime,
        'reply_to', m.reply_to, 'created_at', m.created_at, 'edited_at', m.edited_at, 'deleted_at', m.deleted_at,
        'is_read', exists (select 1 from public.message_reads r where r.message_id = m.id and r.user_id <> m.sender_id),
        'reply', (select jsonb_build_object('id', rm.id, 'content', rm.content, 'sender_id', rm.sender_id,
                    'message_type', rm.message_type, 'deleted', rm.deleted_at is not null)
                  from public.messages rm where rm.id = m.reply_to)
      ) as j
    from public.messages m
    where m.chat_id = p_chat and (p_before is null or m.created_at < p_before)
    order by m.created_at desc limit least(greatest(p_limit, 1), 100)
  ) x;
  return res;
end $$;

create or replace function public.create_direct_chat(p_user uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id(); k text; cid uuid;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if p_user is null or p_user = me then raise exception 'invalid user'; end if;
  if not exists (select 1 from public.users u where u.id = p_user and not u.is_banned and u.telegram_id is not null) then
    raise exception 'user not found';
  end if;
  k := least(me::text, p_user::text) || ':' || greatest(me::text, p_user::text);
  select id into cid from public.chats where direct_key = k;
  if cid is null then
    insert into public.chats (type, direct_key, created_by) values ('direct', k, me)
      on conflict (direct_key) do nothing returning id into cid;
    if cid is null then select id into cid from public.chats where direct_key = k; end if;
    insert into public.chat_members (chat_id, user_id) values (cid, me), (cid, p_user) on conflict do nothing;
  end if;
  return cid;
end $$;

create or replace function public.mark_chat_read(p_chat uuid) returns int
language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id(); n int;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if not public.is_chat_member(p_chat) then raise exception 'forbidden' using errcode = '42501'; end if;
  insert into public.message_reads (message_id, user_id, chat_id)
    select m.id, me, m.chat_id from public.messages m
    where m.chat_id = p_chat and m.sender_id <> me and m.deleted_at is null
      and not exists (select 1 from public.message_reads r where r.message_id = m.id and r.user_id = me)
    on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.delete_message(p_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id(); n int;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  update public.messages set deleted_at = now(), content = '', file_path = null, file_name = null,
         file_size = null, file_mime = null
   where id = p_id and sender_id = me and deleted_at is null;
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.search_users(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid := public.current_user_id(); q text := btrim(coalesce(p_q, '')); qid text; res jsonb;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if char_length(q) < 2 then return '[]'::jsonb; end if;
  qid := public.normalize_identifier(case when left(q,1) = '+' then q else '+' || q end);
  select coalesce(jsonb_agg(public.profile_json(u.id)), '[]'::jsonb) into res from (
    select u.id from public.users u
    left join public.user_settings s on s.user_id = u.id
    where u.id <> me and not u.is_banned and u.telegram_id is not null
      and (
        lower(u.username) like lower(replace(replace(ltrim(q,'@'), '%', ''), '_', '\_')) || '%'
        or lower(u.display_name) like '%' || lower(replace(replace(q, '%', ''), '_', '\_')) || '%'
        or (qid is not null and u.login_identifier = qid and coalesce(s.find_by_identifier, true))
      )
    order by u.display_name limit 20) u;
  return res;
end $$;

create or replace function public.update_profile(p_display_name text, p_avatar_url text default null, p_clear_avatar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id(); n text := btrim(coalesce(p_display_name, ''));
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  if char_length(n) < 1 or char_length(n) > 64 then raise exception 'invalid name'; end if;
  update public.users set display_name = n,
     avatar_url = case when p_clear_avatar then null when p_avatar_url is not null then p_avatar_url else avatar_url end
   where id = me;
  return public.profile_json(me);
end $$;

create or replace function public.get_my_settings() returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id(); r public.user_settings;
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into public.user_settings (user_id) values (me) on conflict do nothing;
  select * into r from public.user_settings where user_id = me;
  return jsonb_build_object('find_by_identifier', r.find_by_identifier,
                            'show_last_seen', r.show_last_seen, 'notifications', r.notifications);
end $$;

create or replace function public.update_settings(p_find_by_identifier boolean, p_show_last_seen boolean, p_notifications boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id();
begin
  if me is null then raise exception 'not authenticated' using errcode = '28000'; end if;
  insert into public.user_settings (user_id, find_by_identifier, show_last_seen, notifications)
    values (me, p_find_by_identifier, p_show_last_seen, p_notifications)
  on conflict (user_id) do update set find_by_identifier = excluded.find_by_identifier,
     show_last_seen = excluded.show_last_seen, notifications = excluded.notifications, updated_at = now();
  return public.get_my_settings();
end $$;

create or replace function public.touch_presence() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := public.current_user_id();
begin
  if me is not null then update public.users set last_seen_at = now() where id = me; end if;
end $$;

-- ===== Серверные функции (только service_role) =====

-- Бот: запоминаем контакт и обновляем username
create or replace function public.srv_bot_touch(p_tg bigint, p_username text, p_first text, p_last text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u public.users; un text := nullif(ltrim(btrim(coalesce(p_username,'')), '@'), '');
begin
  if un is not null then
    update public.bot_contacts set username = null where lower(username) = lower(un) and telegram_id <> p_tg;
    update public.users set username = null where lower(username) = lower(un) and telegram_id is distinct from p_tg;
  end if;
  insert into public.bot_contacts (telegram_id, username, first_name, last_name)
    values (p_tg, un, p_first, p_last)
  on conflict (telegram_id) do update set username = excluded.username,
     first_name = excluded.first_name, last_name = excluded.last_name, updated_at = now();
  update public.users set username = un where telegram_id = p_tg and username is distinct from un;
  select * into u from public.users where telegram_id = p_tg;
  if u.id is null then return jsonb_build_object('registered', false); end if;
  return jsonb_build_object('registered', true, 'user_id', u.id, 'identifier', u.login_identifier);
end $$;

-- Регистрация: один Telegram ID = один аккаунт = один идентификатор (атомарно)
create or replace function public.srv_register_user(p_tg bigint, p_prefix text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare u public.users; c public.bot_contacts; ident text; tries int := 0; new_id uuid; dn text;
begin
  if p_prefix not in ('+1', '+7') then raise exception 'bad prefix'; end if;
  perform pg_advisory_xact_lock(hashtextextended('reg:' || p_tg::text, 0));
  select * into u from public.users where telegram_id = p_tg;
  if u.id is not null then
    return jsonb_build_object('status', 'exists', 'user_id', u.id, 'identifier', u.login_identifier);
  end if;
  select * into c from public.bot_contacts where telegram_id = p_tg;
  dn := coalesce(nullif(btrim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''),
                 nullif(c.username, ''), 'User');
  loop
    tries := tries + 1;
    if tries > 50 then raise exception 'cannot generate identifier'; end if;
    if p_prefix = '+1' then
      ident := '+1' || (2 + (get_byte(gen_random_bytes(1), 0) % 8))::text || public.random_digits(2)
               || (2 + (get_byte(gen_random_bytes(1), 0) % 8))::text || public.random_digits(6);
    else
      ident := '+79' || public.random_digits(9);
    end if;
    continue when exists (select 1 from public.revoked_identifiers where identifier = ident);
    begin
      insert into public.users (telegram_id, username, display_name, login_identifier)
        values (p_tg, c.username, dn, ident) returning id into new_id;
      exit;
    exception when unique_violation then
      -- коллизия идентификатора: пробуем следующий; коллизия telegram_id невозможна (advisory lock)
      continue;
    end;
  end loop;
  insert into public.user_settings (user_id) values (new_id) on conflict do nothing;
  return jsonb_build_object('status', 'created', 'user_id', new_id, 'identifier', ident);
end $$;

-- Вход: поиск пользователя по идентификатору
create or replace function public.srv_auth_lookup(p_identifier text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ident text := public.normalize_identifier(p_identifier); u public.users;
begin
  if ident is null then return null; end if;
  select * into u from public.users where login_identifier = ident;
  if u.id is null or u.is_banned or u.telegram_id is null then return null; end if;
  return jsonb_build_object('user_id', u.id, 'telegram_id', u.telegram_id);
end $$;

create or replace function public.srv_auth_create_code(p_user uuid, p_hash text, p_ttl_seconds int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare last_ts timestamptz; hourly int; cid uuid;
begin
  perform pg_advisory_xact_lock(hashtextextended('code:' || p_user::text, 0));
  select max(created_at) into last_ts from public.login_codes where user_id = p_user;
  if last_ts is not null and last_ts > now() - interval '60 seconds' then
    return jsonb_build_object('ok', false, 'reason', 'cooldown');
  end if;
  select count(*) into hourly from public.login_codes where user_id = p_user and created_at > now() - interval '1 hour';
  if hourly >= 5 then return jsonb_build_object('ok', false, 'reason', 'hourly_limit'); end if;
  update public.login_codes set used = true where user_id = p_user and not used;
  insert into public.login_codes (user_id, code_hash, expires_at)
    values (p_user, p_hash, now() + make_interval(secs => p_ttl_seconds)) returning id into cid;
  return jsonb_build_object('ok', true, 'code_id', cid);
end $$;

create or replace function public.srv_auth_fail_code(p_code uuid) returns void
language sql security definer set search_path = public as $$
  update public.login_codes set used = true where id = p_code;
$$;

-- Последний код пользователя (в т.ч. просроченный, чтобы показать «код истёк»)
create or replace function public.srv_auth_get_code(p_identifier text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ident text := public.normalize_identifier(p_identifier); u public.users; c public.login_codes;
begin
  if ident is null then return null; end if;
  select * into u from public.users where login_identifier = ident;
  if u.id is null or u.is_banned or u.telegram_id is null then return null; end if;
  select * into c from public.login_codes where user_id = u.id and not used order by created_at desc limit 1;
  if c.id is null then return null; end if;
  return jsonb_build_object('code_id', c.id, 'user_id', u.id, 'code_hash', c.code_hash,
    'expired', c.expires_at <= now(), 'attempts', c.attempts);
end $$;

-- Атомарно увеличиваем число попыток; при >=5 код сгорает
create or replace function public.srv_auth_bump_attempt(p_code uuid) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.login_codes set attempts = attempts + 1, used = used or attempts + 1 >= 5
   where id = p_code returning attempts into n;
  return coalesce(n, 99);
end $$;

-- Одноразовое использование: true только для первого вызова
create or replace function public.srv_auth_consume_code(p_code uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update public.login_codes set used = true where id = p_code and not used and expires_at > now();
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.srv_auth_create_session(p_user uuid, p_token_hash text, p_ttl_seconds int, p_device text)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if not exists (select 1 from public.users where id = p_user and not is_banned and telegram_id is not null) then
    return null;
  end if;
  insert into public.user_sessions (user_id, token_hash, device, expires_at)
    values (p_user, p_token_hash, left(p_device, 200), now() + make_interval(secs => p_ttl_seconds)) returning id into sid;
  update public.users set last_seen_at = now() where id = p_user;
  return sid;
end $$;

create or replace function public.srv_auth_refresh(p_old_hash text, p_new_hash text, p_ttl_seconds int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.user_sessions;
begin
  select * into s from public.user_sessions where token_hash = p_old_hash for update;
  if s.id is null or s.revoked_at is not null or s.expires_at <= now() then return null; end if;
  if not exists (select 1 from public.users where id = s.user_id and not is_banned and telegram_id is not null) then return null; end if;
  update public.user_sessions set token_hash = p_new_hash, expires_at = now() + make_interval(secs => p_ttl_seconds) where id = s.id;
  update public.users set last_seen_at = now() where id = s.user_id;
  return jsonb_build_object('session_id', s.id, 'user_id', s.user_id);
end $$;

create or replace function public.srv_auth_revoke_session(p_session uuid) returns void
language sql security definer set search_path = public as $$
  update public.user_sessions set revoked_at = now() where id = p_session and revoked_at is null;
$$;

create or replace function public.srv_admin_log(p_admin bigint, p_action text, p_target uuid, p_details jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.admin_logs (admin_telegram_id, action, target_user_id, details)
  values (p_admin, p_action, p_target, p_details);
$$;

create or replace function public.srv_admin_find(p_username text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare un text := lower(ltrim(btrim(coalesce(p_username,'')), '@')); u public.users;
begin
  if un = '' then return null; end if;
  select * into u from public.users where lower(username) = un and telegram_id is not null order by updated_at desc limit 1;
  if u.id is null then return null; end if;
  return jsonb_build_object('user_id', u.id, 'telegram_id', u.telegram_id, 'username', u.username,
                            'display_name', u.display_name, 'identifier', u.login_identifier);
end $$;

create or replace function public.srv_admin_add_number(p_admin bigint, p_username text, p_identifier text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare un text := lower(ltrim(btrim(coalesce(p_username,'')), '@')); ident text := public.normalize_identifier(p_identifier);
        c public.bot_contacts; u public.users; new_id uuid; dn text;
begin
  if ident is null then return jsonb_build_object('error', 'bad_identifier'); end if;
  select * into c from public.bot_contacts where lower(username) = un order by updated_at desc limit 1;
  if c.telegram_id is null then return jsonb_build_object('error', 'not_started'); end if;
  perform pg_advisory_xact_lock(hashtextextended('reg:' || c.telegram_id::text, 0));
  select * into u from public.users where telegram_id = c.telegram_id;
  if u.id is not null then return jsonb_build_object('error', 'already_has', 'identifier', u.login_identifier); end if;
  if exists (select 1 from public.users where login_identifier = ident) then return jsonb_build_object('error', 'taken'); end if;
  if exists (select 1 from public.revoked_identifiers where identifier = ident) then return jsonb_build_object('error', 'revoked'); end if;
  dn := coalesce(nullif(btrim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), c.username, 'User');
  insert into public.users (telegram_id, username, display_name, login_identifier)
    values (c.telegram_id, c.username, dn, ident) returning id into new_id;
  insert into public.user_settings (user_id) values (new_id) on conflict do nothing;
  insert into public.admin_logs (admin_telegram_id, action, target_user_id, details)
    values (p_admin, 'addnumber', new_id, jsonb_build_object('identifier', ident, 'username', c.username));
  return jsonb_build_object('ok', true, 'user_id', new_id, 'telegram_id', c.telegram_id, 'identifier', ident);
end $$;

create or replace function public.srv_admin_unlink(p_admin bigint, p_user uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u public.users;
begin
  select * into u from public.users where id = p_user for update;
  if u.id is null or u.telegram_id is null then return jsonb_build_object('error', 'not_found'); end if;
  update public.user_sessions set revoked_at = now() where user_id = u.id and revoked_at is null;
  update public.login_codes set used = true where user_id = u.id and not used;
  if u.login_identifier is not null then
    insert into public.revoked_identifiers (identifier, former_user_id) values (u.login_identifier, u.id) on conflict do nothing;
  end if;
  update public.users set telegram_id = null, login_identifier = null, unlinked_at = now() where id = u.id;
  insert into public.admin_logs (admin_telegram_id, action, target_user_id, details)
    values (p_admin, 'unlink', u.id, jsonb_build_object('identifier', u.login_identifier,
            'telegram_id', u.telegram_id, 'username', u.username));
  return jsonb_build_object('ok', true, 'telegram_id', u.telegram_id, 'identifier', u.login_identifier);
end $$;
