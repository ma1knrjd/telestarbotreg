-- Тест миграций (запуск на локальном Postgres с заглушками Supabase). Каждая проверка падает с ошибкой при сбое.
\set ON_ERROR_STOP on
create or replace function pg_temp.assert(c boolean, m text) returns void language plpgsql as $$ begin if not c then raise exception 'FAIL: %', m; end if; end $$;
select srv_bot_touch(1001, 'alice', 'Alice', 'A');
select srv_bot_touch(1002, 'bob', 'Bob', null);
select pg_temp.assert((select (srv_register_user(1001,'+1')->>'identifier') ~ '^\+1[2-9][0-9]{2}[2-9][0-9]{6}$'), 'alice +1 format');
select pg_temp.assert((select srv_register_user(1001,'+7')->>'status') = 'exists', 'second registration refused');
select pg_temp.assert((select (srv_register_user(1002,'+7')->>'identifier') ~ '^\+79[0-9]{9}$'), 'bob +7 format');
select pg_temp.assert((select count(*) from users)=2, 'two users');
-- коды
select srv_auth_create_code((select id from users where username='alice'), 'h1', 300) as r \gset
select pg_temp.assert((:'r'::jsonb->>'ok')::boolean, 'code created');
select pg_temp.assert((select srv_auth_create_code((select id from users where username='alice'),'h2',300)->>'reason')='cooldown','cooldown');
select pg_temp.assert((select code_hash from login_codes limit 1)='h1','hash stored');
select pg_temp.assert(srv_auth_consume_code((:'r'::jsonb->>'code_id')::uuid), 'consume first');
select pg_temp.assert(not srv_auth_consume_code((:'r'::jsonb->>'code_id')::uuid), 'consume second refused');
-- попытки
update login_codes set used=false;
select srv_auth_bump_attempt(id) from login_codes; select srv_auth_bump_attempt(id) from login_codes; select srv_auth_bump_attempt(id) from login_codes; select srv_auth_bump_attempt(id) from login_codes;
select pg_temp.assert((select not used from login_codes),'not burned at 4');
select srv_auth_bump_attempt(id) from login_codes;
select pg_temp.assert((select used from login_codes),'burned at 5');
-- сессии
select srv_auth_create_session((select id from users where username='alice'),'t_a',3600,'test') as sa \gset
select srv_auth_create_session((select id from users where username='bob'),'t_b',3600,'test') as sb \gset
select id as ua from users where username='alice' \gset
select id as ub from users where username='bob' \gset
-- клиент alice
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',:'ua','sid',:'sa')::text, false);
select pg_temp.assert(current_user_id() = :'ua'::uuid, 'alice current_user_id');
select create_direct_chat(:'ub'::uuid) as cid \gset
select pg_temp.assert(create_direct_chat(:'ub'::uuid) = :'cid'::uuid, 'direct chat deduplicated');
insert into messages(chat_id, sender_id, content) values (:'cid', :'ua', 'hello');
-- подделка отправителя
do $$ begin
  begin insert into messages(chat_id, sender_id, content) values ((select id from chats limit 1), (select id from users where username='bob'), 'spoof');
        raise exception 'FAIL: spoof allowed'; exception when insufficient_privilege then null; end;
end $$;
-- telegram_id недоступен
do $$ begin
  begin perform telegram_id from users; raise exception 'FAIL: telegram_id readable'; exception when insufficient_privilege then null; end;
end $$;
do $$ begin
  begin perform * from login_codes; raise exception 'FAIL: login_codes readable'; exception when insufficient_privilege then null; end;
  begin perform * from user_sessions; raise exception 'FAIL: sessions readable'; exception when insufficient_privilege then null; end;
  begin update users set display_name='x'; raise exception 'FAIL: users update'; exception when insufficient_privilege then null; end;
  begin update messages set content='x'; raise exception 'FAIL: messages update'; exception when insufficient_privilege then null; end;
  begin perform srv_admin_unlink(1, (select id from users limit 1)); raise exception 'FAIL: srv fn callable'; exception when insufficient_privilege then null; end;
end $$;
select pg_temp.assert((select count(*) from users)=1, 'alice sees only self in users');
select pg_temp.assert(jsonb_array_length(search_users('bob'))=1, 'search by username');
select pg_temp.assert(jsonb_array_length(search_users('+'||substr((select 'x'),1,0)||'0'))=0, 'bad search empty');
-- bob
select set_config('request.jwt.claims', json_build_object('sub',:'ub','sid',:'sb')::text, false);
select pg_temp.assert((select count(*) from messages)=1, 'bob sees message');
select pg_temp.assert((get_chat_list()->0->>'unread')::int=1, 'unread=1');
select pg_temp.assert(not delete_message((select id from messages limit 1)), 'bob cannot delete alice msg');
select pg_temp.assert(mark_chat_read(:'cid'::uuid)=1, 'marked read');
select pg_temp.assert((get_chat_list()->0->>'unread')::int=0, 'unread=0');
-- alice видит прочтение
select set_config('request.jwt.claims', json_build_object('sub',:'ua','sid',:'sa')::text, false);
select pg_temp.assert((get_chat_messages(:'cid'::uuid)->0->>'is_read')::boolean, 'is_read true');
select pg_temp.assert(delete_message((select id from messages limit 1)), 'alice deletes own');
select pg_temp.assert((get_chat_messages(:'cid'::uuid)->0->>'deleted_at') is not null, 'soft deleted');
-- чужой посторонний
reset role;
select srv_bot_touch(1003,'eve','Eve',null); select srv_register_user(1003,'+1');
select srv_auth_create_session((select id from users where username='eve'),'t_e',3600,'t') as se \gset
select id as ue from users where username='eve' \gset
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',:'ue','sid',:'se')::text, false);
select pg_temp.assert((select count(*) from messages)=0, 'eve sees no messages');
select pg_temp.assert((select count(*) from chats)=0, 'eve sees no chats');
do $$ begin
  begin insert into messages(chat_id, sender_id, content) values ((select id from chats limit 1), (select id from users where username='eve'), 'x'); exception when others then null; end;
end $$;
select pg_temp.assert(not storage_chat_access(:'cid' || '/f.png'), 'eve no storage access');
select set_config('request.jwt.claims', json_build_object('sub',:'ua','sid',:'sa')::text, false);
select pg_temp.assert(storage_chat_access(:'cid' || '/f.png'), 'alice storage access');
-- админ: addnumber / unlink
reset role;
select pg_temp.assert((select srv_admin_add_number(1,'@nobody','+8880')->>'error')='not_started','addnumber unknown');
select srv_bot_touch(1004,'carol','Carol',null);
select pg_temp.assert((select srv_admin_add_number(1,'@carol','+888 0000')->>'identifier')='+8880000','addnumber ok');
select pg_temp.assert((select srv_admin_add_number(1,'@carol','+8881')->>'error')='already_has','addnumber duplicate user');
select pg_temp.assert((select srv_admin_add_number(1,'@eve','+8880000')->>'error')='already_has','eve has already');
select pg_temp.assert((select srv_auth_lookup('+888 0000') is not null),'lookup normalized');
select pg_temp.assert((select (srv_admin_unlink(1,(select id from users where username='alice'))->>'ok')::boolean),'unlink');
select pg_temp.assert((select srv_auth_lookup((select login_identifier from users where username='bob')) is not null),'bob unaffected');
select pg_temp.assert((select srv_auth_lookup('+1234567890') is null),'unknown identifier');
-- после unlink сессия alice не работает
set role authenticated;
select set_config('request.jwt.claims', json_build_object('sub',:'ua','sid',:'sa')::text, false);
select pg_temp.assert(current_user_id() is null, 'unlinked session dead');
do $$ begin begin perform get_chat_list(); raise exception 'FAIL: dead session works'; exception when sqlstate '28000' then null; end; end $$;
reset role;
select pg_temp.assert((select count(*) from revoked_identifiers)=1,'identifier revoked');
select pg_temp.assert((select count(*) from admin_logs)=2,'admin logs written');
select pg_temp.assert(srv_auth_refresh('t_a','n',100) is null, 'refresh of revoked session refused');
select pg_temp.assert(srv_auth_refresh('t_b','n_b',100) is not null, 'refresh rotates');
select pg_temp.assert(srv_auth_refresh('t_b','n_b2',100) is null, 'old refresh token dead');
select 'ALL SQL TESTS PASSED' as result;
