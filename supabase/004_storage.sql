-- TeleStar: Supabase Storage
insert into storage.buckets (id, name, public, file_size_limit)
values ('avatars', 'avatars', true, 5242880)
on conflict (id) do update set public = true, file_size_limit = 5242880;

insert into storage.buckets (id, name, public, file_size_limit)
values ('chat-files', 'chat-files', false, 26214400)
on conflict (id) do update set public = false, file_size_limit = 26214400;

-- avatars: писать можно только в свою папку <user_id>/...
drop policy if exists avatars_insert on storage.objects;
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.current_user_id()::text);
drop policy if exists avatars_update on storage.objects;
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.current_user_id()::text);
drop policy if exists avatars_delete on storage.objects;
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = public.current_user_id()::text);

-- chat-files: путь <chat_id>/<файл>; доступ только участникам чата
drop policy if exists chatfiles_select on storage.objects;
create policy chatfiles_select on storage.objects for select to authenticated
  using (bucket_id = 'chat-files' and public.storage_chat_access(name));
drop policy if exists chatfiles_insert on storage.objects;
create policy chatfiles_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'chat-files' and public.storage_chat_access(name));
