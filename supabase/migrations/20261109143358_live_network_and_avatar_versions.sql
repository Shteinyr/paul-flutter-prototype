-- Edge validates grapheme counts. Byte caps here retain a bounded database
-- representation without rejecting multi-codepoint characters accepted by UI.
alter table public.profiles drop constraint profiles_name_check;
alter table public.profiles drop constraint profiles_occupation_check;
alter table public.profiles drop constraint profiles_summary_check;
alter table public.profiles add check (length(btrim(name)) >= 1 and octet_length(name) <= 32768);
alter table public.profiles add check (octet_length(occupation) <= 32768);
alter table public.profiles add check (length(btrim(summary)) >= 1 and octet_length(summary) <= 32768);

create or replace function private.valid_skills(items text[], required boolean) returns boolean
language sql immutable set search_path = '' as $$
  select items is not null and cardinality(items) between (case when required then 1 else 0 end) and 100
    and not exists(select 1 from unnest(items) s where s is null or length(btrim(s)) < 1 or octet_length(s) > 32768);
$$;

create function private.owns_avatar(member_id uuid, avatar text) returns boolean
language sql stable set search_path = '' as $$
  select avatar is not null and avatar ~ ('^' || member_id::text || '/[a-f0-9]{64}[.]png$')
    and exists(select 1 from storage.objects where bucket_id = 'avatars' and name = avatar and owner_id = member_id::text);
$$;
revoke all on function private.owns_avatar(uuid, text) from public, anon, authenticated;
grant execute on function private.owns_avatar(uuid, text) to service_role;

create or replace function private.save_profile(member_id uuid, draft jsonb) returns void
language plpgsql set search_path = '' as $$
declare offered text[]; searching text[]; avatar text;
begin
  if jsonb_typeof(draft->'skills') is distinct from 'array'
    or jsonb_typeof(draft->'searching_skills') is distinct from 'array' then raise exception 'invalid_profile'; end if;
  if exists(select 1 from jsonb_array_elements(draft->'skills') s where jsonb_typeof(s) <> 'string')
    or exists(select 1 from jsonb_array_elements(draft->'searching_skills') s where jsonb_typeof(s) <> 'string') then
    raise exception 'invalid_profile';
  end if;
  offered := array(select jsonb_array_elements_text(draft->'skills'));
  searching := array(select jsonb_array_elements_text(draft->'searching_skills'));
  if not private.valid_skills(offered, true) or not private.valid_skills(searching, false) then raise exception 'invalid_profile'; end if;
  avatar := nullif(draft->>'avatar_path', '');
  if avatar is not null and not private.owns_avatar(member_id, avatar) then raise exception 'invalid_profile'; end if;
  insert into public.profiles(id, name, occupation, summary, skills, searching_skills, avatar_path)
  values(member_id, btrim(draft->>'name'), coalesce(btrim(draft->>'occupation'), ''), btrim(draft->>'summary'), offered, searching, avatar)
  on conflict(id) do update set name = excluded.name, occupation = excluded.occupation,
    summary = excluded.summary, skills = excluded.skills, searching_skills = excluded.searching_skills,
    avatar_path = excluded.avatar_path, updated_at = clock_timestamp();
end;
$$;

create function public.member_network(p_user uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'profile', (select to_jsonb(p) || jsonb_build_object('contact_count',
      (select count(*) from public.connections c where c.user_low=p.id or c.user_high=p.id))
      from public.profiles p where p.id=p_user and exists(select 1 from private.memberships where user_id=p_user)),
    'contacts', coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('contact_count',
      (select count(*) from public.connections c where c.user_low=p.id or c.user_high=p.id)))
      from public.profiles p join public.connections c
      on (c.user_low=p_user and c.user_high=p.id) or (c.user_high=p_user and c.user_low=p.id)
      where exists(select 1 from private.memberships where user_id=p_user)), '[]'::jsonb)
  );
$$;
revoke all on function public.member_network(uuid) from public, anon, authenticated;
grant execute on function public.member_network(uuid) to service_role;

drop policy avatar_insert on storage.objects;
drop policy avatar_update on storage.objects;
drop policy avatar_owner_read on storage.objects;
create policy avatar_insert on storage.objects for insert to authenticated
  with check (bucket_id='avatars' and name ~ ('^' || (select auth.uid())::text || '/[a-f0-9]{64}[.]png$'));
create policy avatar_update on storage.objects for update to authenticated
  using (bucket_id='avatars' and name ~ ('^' || (select auth.uid())::text || '/[a-f0-9]{64}[.]png$'))
  with check (bucket_id='avatars' and name ~ ('^' || (select auth.uid())::text || '/[a-f0-9]{64}[.]png$'));
create policy avatar_owner_read on storage.objects for select to authenticated
  using (bucket_id='avatars' and name ~ ('^' || (select auth.uid())::text || '/[a-f0-9]{64}[.]png$'));
grant usage on schema storage to service_role;
grant select on storage.objects to service_role;

create or replace function public.redeem_invitation(p_user uuid, p_hash text, p_manual boolean, p_profile jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.invitations; already_member boolean;
begin
  -- A per-user lock serializes first registration with different invitations.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text, 0));
  select * into item from private.invitations
    where (not p_manual and token_hash = p_hash) or (p_manual and code_hash = p_hash)
    for update;
  if not found then raise exception 'invalid_invitation'; end if;
  if exists(select 1 from private.invite_redemptions where invitation_id = item.id and user_id = p_user) then
    return jsonb_build_object('connected', item.issuer_id is not null, 'replayed', true);
  end if;
  if item.issuer_id = p_user then raise exception 'own_invitation'; end if;
  if item.revoked_at is not null or item.expires_at <= clock_timestamp()
    or (item.max_uses is not null and item.uses >= item.max_uses) then
    raise exception 'invalid_invitation';
  end if;
  if item.issuer_id is not null and not exists(select 1 from private.memberships where user_id = item.issuer_id) then
    raise exception 'invalid_invitation';
  end if;
  already_member := exists(select 1 from private.memberships where user_id = p_user);
  if not already_member then
    if not private.owns_avatar(p_user, p_profile->>'avatar_path') then raise exception 'invalid_profile'; end if;
    perform private.save_profile(p_user, p_profile);
    insert into private.memberships(user_id) values(p_user);
  end if;
  if item.issuer_id is not null then
    insert into public.connections(user_low, user_high)
      values(least(p_user, item.issuer_id), greatest(p_user, item.issuer_id)) on conflict do nothing;
  end if;
  insert into private.invite_redemptions(invitation_id, user_id) values(item.id, p_user);
  update private.invitations set uses = uses + 1 where id = item.id;
  return jsonb_build_object('connected', item.issuer_id is not null, 'replayed', false);
end;
$$;
