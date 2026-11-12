create index if not exists profiles_avatar_reference_idx on public.profiles(avatar_path) where avatar_path is not null;

-- #73: metadata journal only. File deletion ALWAYS uses the Storage API.
create table private.avatar_cleanup_settings(singleton boolean primary key default true check(singleton),enabled boolean not null default false);
insert into private.avatar_cleanup_settings values(true,false);
create table private.avatar_uploads(
  path text primary key check(path ~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/[a-f0-9]{64}[.]png$'),
  owner_profile_id uuid not null,
  object_id uuid,
  source text not null check(source in('upload','reference','legacy')),
  state text not null default 'pending' check(state in('pending','deleting','deleted','blocked')),
  protected_until timestamptz not null default clock_timestamp()+interval '24 hours',
  next_attempt_at timestamptz not null default clock_timestamp(),
  lease_token uuid,lease_until timestamptz,
  attempts integer not null default 0,
  last_error text check(last_error in('storage_unavailable','cleanup_pending','reference_conflict')),
  created_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz
);
create index avatar_uploads_due on private.avatar_uploads(next_attempt_at,path) where state in('pending','deleting');
create table private.avatar_admin_uploads(
  actor_id uuid not null,operation_id uuid not null,content_hash text not null check(content_hash ~ '^[a-f0-9]{64}$'),
  profile_id uuid not null,path text not null references private.avatar_uploads(path),
  primary key(actor_id,operation_id)
);
alter table private.avatar_cleanup_settings enable row level security;
alter table private.avatar_uploads enable row level security;
alter table private.avatar_admin_uploads enable row level security;
revoke all on private.avatar_cleanup_settings,private.avatar_uploads,private.avatar_admin_uploads from public,anon,authenticated;
grant all on private.avatar_cleanup_settings,private.avatar_uploads,private.avatar_admin_uploads to service_role;

create function private.avatar_path_known(p_path text) returns boolean language sql stable set search_path='' as $$
 select p_path ~ '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}/[a-f0-9]{64}[.]png$';
$$;
create function private.avatar_path_lock(p_path text) returns void language sql set search_path='' as $$
 select pg_advisory_xact_lock(hashtextextended(p_path,7300));
$$;
create function private.avatar_known_owner(p_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=p_id)
   or exists(select 1 from public.profiles where id=p_id and deleted_at is null)
   or exists(select 1 from private.managed_profile_reservations where profile_id=p_id);
$$;
create function private.avatar_account_deletion(p_id uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from private.account_deletions where target_profile_id=p_id or p_id=any(abandoned_profile_ids));
$$;
create function private.avatar_protected(p_path text) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.profiles where avatar_path=p_path)
   or private.avatar_account_deletion(split_part(p_path,'/',1)::uuid)
   or exists(select 1 from private.managed_profile_reservations r
     where r.profile_id=split_part(p_path,'/',1)::uuid and r.created_at>clock_timestamp()-interval '24 hours'
       and not exists(select 1 from public.profiles where id=r.profile_id));
$$;
create function private.avatar_begin(p_path text,p_source text,p_object uuid default null) returns void
language plpgsql set search_path='' as $$
begin
 if private.avatar_path_known(p_path) is distinct from true then raise exception 'invalid_profile';end if;
 perform private.avatar_path_lock(p_path);
 if exists(select 1 from private.avatar_uploads where path=p_path and state<>'pending') then
   raise exception 'avatar_retired';
 end if;
 insert into private.avatar_uploads(path,owner_profile_id,object_id,source)
 values(p_path,split_part(p_path,'/',1)::uuid,p_object,p_source)
 on conflict(path) do update set protected_until=clock_timestamp()+interval '24 hours',
   object_id=coalesce(excluded.object_id,private.avatar_uploads.object_id);
end;$$;

-- Before registration there is Auth but no membership. Pin the real live session.
create function public.avatar_upload_begin(p_path text) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();session_key text:=auth.jwt()->>'session_id';
begin
 if actor is null or coalesce((auth.jwt()->>'is_anonymous')::boolean,false)
   or private.avatar_path_known(p_path) is distinct from true or split_part(p_path,'/',1)<>actor::text then
   raise exception 'sign_in_required';
 end if;
 if session_key is null or session_key !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' then raise exception 'session_revoked';end if;
 if not private.push_session_active(actor,session_key::uuid) then raise exception 'session_revoked';end if;
 if not exists(select 1 from auth.users where id=actor) or private.avatar_account_deletion(actor)
   or exists(select 1 from public.profiles where id=actor and deleted_at is not null) then raise exception 'profile_unavailable';end if;
 perform private.avatar_begin(p_path,'upload');
end;$$;

-- Run AFTER guard_deleted_avatar: profile/reservation -> path lock order matches
-- account deletion/finalization. Never take a profile row lock after a path lock.
create function private.avatar_storage_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.bucket_id='avatars' and private.avatar_path_known(new.name) then
   perform private.avatar_path_lock(new.name);
   if exists(select 1 from private.avatar_uploads where path=new.name and state<>'pending') then raise exception 'avatar_retired';end if;
   if not private.avatar_known_owner(split_part(new.name,'/',1)::uuid) then return new;end if;
   perform private.avatar_begin(new.name,'upload',new.id);
 end if;
 return new;
end;$$;
create trigger zz_avatar_lifecycle before insert or update on storage.objects
 for each row execute function private.avatar_storage_guard();

create function private.avatar_reference_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare path_key text;previous_path text;
begin
 if tg_op='UPDATE' then previous_path:=old.avatar_path;end if;
 -- Sorted per-path locks also handle swaps consistently. Profile row lock first.
 for path_key in select distinct x from unnest(array[previous_path,new.avatar_path])x
   where private.avatar_path_known(x) order by x loop
   perform private.avatar_path_lock(path_key);
   if path_key=new.avatar_path and exists(select 1 from private.avatar_uploads where path=path_key and state<>'pending') then
     raise exception 'avatar_retired';
   end if;
   -- Existing references are proven application objects; historical orphans are NOT adopted here.
   insert into private.avatar_uploads(path,owner_profile_id,object_id,source)
   select path_key,split_part(path_key,'/',1)::uuid,o.id,'reference'
     from storage.objects o where bucket_id='avatars' and name=path_key
   on conflict(path) do nothing;
 end loop;
 return new;
end;$$;
create trigger avatar_lifecycle_reference before insert or update of avatar_path on public.profiles
 for each row execute function private.avatar_reference_guard();

create function public.admin_avatar_upload_begin(p_actor uuid,p_profile uuid,p_create boolean,p_operation uuid,p_hash text)
returns jsonb language plpgsql set search_path='' as $$
declare upload private.avatar_admin_uploads;receipt private.admin_audit;key text;
begin
 if p_hash is null or p_hash !~ '^[a-f0-9]{64}$' then raise exception 'invalid_profile';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_actor::text||p_operation::text,7301));
 perform public.admin_authorize_save(p_actor,p_profile,p_create,p_operation);
 select * into upload from private.avatar_admin_uploads where actor_id=p_actor and operation_id=p_operation;
 if found and (upload.content_hash<>p_hash or upload.profile_id<>p_profile) then raise exception 'operation_id_conflict';end if;
 select * into receipt from private.admin_audit where actor_user_id=p_actor and client_operation_id=p_operation;
 if found then
   key:=receipt.details->'request'->'draft'->>'avatar_path';
   if receipt.profile_id<>p_profile or receipt.action not in('profile_create','profile_edit')
     or key is null or (upload.path is null and key<>p_profile::text||'/'||p_hash||'.png') then
     raise exception 'operation_id_conflict';
   end if;
   -- Replayed saves validate the complete request in admin_save_profile; no upload
   -- may recreate a replaced/deleted version while returning its historical receipt.
   return jsonb_build_object('path',key,'upload',false);
 end if;
 key:=upload.path;
 if key is null or exists(select 1 from private.avatar_uploads where path=key and state<>'pending') then
   key:=p_profile::text||'/'||replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-','')||'.png';
 end if;
 perform private.avatar_begin(key,'upload');
 insert into private.avatar_admin_uploads(actor_id,operation_id,profile_id,content_hash,path)
 values(p_actor,p_operation,p_profile,p_hash,key)
 on conflict(actor_id,operation_id) do update set path=excluded.path;
 return jsonb_build_object('path',key,'upload',true);
end;$$;

-- Read-only inventory. Caller must retain exact object IDs for a reviewed import.
create function public.avatar_cleanup_inventory(p_limit integer default 100,p_after text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit not between 1 and 200 then raise exception 'invalid_request';end if;
 with items as (
   select o.name as path,o.id as object_id,
     case when not private.avatar_path_known(o.name) then 'unknown_path'
       when not private.avatar_known_owner(split_part(o.name,'/',1)::uuid) then 'unknown_owner'
       when private.avatar_protected(o.name) then 'referenced_or_reserved'
       when j.path is null then 'untracked'
       when j.state<>'pending' then j.state
       when j.protected_until>clock_timestamp() then 'grace'
       else 'eligible' end as category
   from storage.objects o left join private.avatar_uploads j on j.path=o.name
   where o.bucket_id='avatars' and (p_after is null or o.name>p_after) order by o.name limit p_limit
 ) select coalesce(jsonb_agg(to_jsonb(items)),'[]'::jsonb) into result from items;
 return result;
end;$$;
create function public.avatar_cleanup_adopt(p_objects jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare item jsonb;path_key text;object_key uuid;amount integer:=0;prefix uuid;
begin
 if jsonb_typeof(p_objects) is distinct from 'array' or jsonb_array_length(p_objects)>100 then raise exception 'invalid_request';end if;
 for item in select x from jsonb_array_elements(p_objects)x order by x->>'path' loop
   if jsonb_typeof(item)<>'object' or (select count(*) from jsonb_object_keys(item))<>2
     or private.avatar_path_known(item->>'path') is distinct from true or jsonb_typeof(item->'object_id') is distinct from 'string'
     or (item->>'object_id') !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' then raise exception 'invalid_request';end if;
   path_key:=item->>'path';object_key:=(item->>'object_id')::uuid;prefix:=split_part(path_key,'/',1)::uuid;
   perform private.avatar_path_lock(path_key);
   if not private.avatar_known_owner(prefix) or private.avatar_protected(path_key)
     or exists(select 1 from private.managed_profile_reservations where profile_id=prefix and not exists(select 1 from public.profiles where id=prefix))
     or not exists(select 1 from storage.objects where bucket_id='avatars' and name=path_key and id=object_key) then raise exception 'inventory_changed';end if;
   -- Idempotent imports do not reset an active lease or resurrect a tombstone.
   insert into private.avatar_uploads(path,owner_profile_id,object_id,source)
     values(path_key,prefix,object_key,'legacy') on conflict(path) do nothing;
   if found then amount:=amount+1;end if;
 end loop;
 return amount;
end;$$;
create function public.avatar_cleanup_set_enabled(p_enabled boolean) returns void language plpgsql set search_path='' as $$
begin
 if p_enabled is null then raise exception 'invalid_request';end if;
 update private.avatar_cleanup_settings set enabled=p_enabled;
end;$$;

create function public.avatar_cleanup_claim(p_limit integer default 5) returns jsonb language plpgsql security definer set search_path='' as $$
declare candidate record;job private.avatar_uploads;result jsonb:='[]'::jsonb;
begin
 if p_limit is null or p_limit not between 1 and 20 then raise exception 'invalid_request';end if;
 if not (select enabled from private.avatar_cleanup_settings where singleton) then return result;end if;
 for candidate in select path from private.avatar_uploads
   where state in('pending','deleting') and not private.avatar_protected(path) and next_attempt_at<=clock_timestamp()
     and protected_until<=clock_timestamp() and (lease_until is null or lease_until<=clock_timestamp())
   order by path limit 200 loop
   -- Never acquire a journal row before its path lock (same order as writers).
   if not pg_try_advisory_xact_lock(hashtextextended(candidate.path,7300)) then continue;end if;
   select * into job from private.avatar_uploads where path=candidate.path for update skip locked;
   if not found or job.state not in('pending','deleting') or job.protected_until>clock_timestamp()
     or job.next_attempt_at>clock_timestamp() or job.lease_until>clock_timestamp() or private.avatar_protected(job.path) then continue;end if;
   update private.avatar_uploads set state='deleting',lease_token=gen_random_uuid(),lease_until=clock_timestamp()+interval '90 seconds',
     attempts=attempts+1 where path=job.path returning * into job;
   result:=result||jsonb_build_array(jsonb_build_object('path',job.path,'lease_token',job.lease_token));
   if jsonb_array_length(result)>=p_limit then exit;end if;
 end loop;
 return result;
end;$$;
create function public.avatar_cleanup_prepare(p_path text,p_lease uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare job private.avatar_uploads;object_key uuid;
begin
 if not (select enabled from private.avatar_cleanup_settings where singleton) then return null;end if;
 perform private.avatar_path_lock(p_path);
 select * into job from private.avatar_uploads where path=p_path for update;
 if not found or job.state<>'deleting' or job.lease_token is distinct from p_lease or job.lease_until<=clock_timestamp() then return null;end if;
 if private.avatar_protected(p_path) then
   update private.avatar_uploads set state='blocked',last_error='reference_conflict',lease_token=null,lease_until=null where path=p_path;
   return null;
 end if;
 select id into object_key from storage.objects where bucket_id='avatars' and name=p_path;
 if object_key is not null and object_key is distinct from job.object_id then
   update private.avatar_uploads set state='blocked',last_error='reference_conflict',lease_token=null,lease_until=null where path=p_path;
   return null;
 end if;
 return jsonb_build_object('path',p_path,'exists',object_key is not null);
end;$$;
create function public.avatar_cleanup_finish(p_path text,p_lease uuid,p_success boolean) returns jsonb language plpgsql security definer set search_path='' as $$
declare job private.avatar_uploads;done boolean;
begin
 perform private.avatar_path_lock(p_path);
 select * into job from private.avatar_uploads where path=p_path for update;
 if not found or job.state<>'deleting' or job.lease_token is distinct from p_lease or job.lease_until<=clock_timestamp() then return null;end if;
 done:=not exists(select 1 from storage.objects where bucket_id='avatars' and name=p_path);
 update private.avatar_uploads set state=case when done then 'deleted' else 'deleting' end,
   completed_at=case when done then clock_timestamp() end,lease_token=null,lease_until=null,
   next_attempt_at=clock_timestamp()+make_interval(secs=>least(3600,30*power(2,least(attempts,7))::integer)),
   last_error=case when done then null when p_success then 'cleanup_pending' else 'storage_unavailable' end
 where path=p_path returning * into job;
 return jsonb_build_object('state',job.state);
end;$$;

revoke all on function private.avatar_path_known(text),private.avatar_path_lock(text),private.avatar_known_owner(uuid),
 private.avatar_account_deletion(uuid),private.avatar_protected(text),private.avatar_begin(text,text,uuid),
 private.avatar_storage_guard(),private.avatar_reference_guard(),public.avatar_upload_begin(text),
 public.admin_avatar_upload_begin(uuid,uuid,boolean,uuid,text),public.avatar_cleanup_inventory(integer,text),
 public.avatar_cleanup_adopt(jsonb),public.avatar_cleanup_set_enabled(boolean),public.avatar_cleanup_claim(integer),
 public.avatar_cleanup_prepare(text,uuid),public.avatar_cleanup_finish(text,uuid,boolean) from public,anon,authenticated;
grant execute on function public.avatar_upload_begin(text) to authenticated;
grant execute on function public.admin_avatar_upload_begin(uuid,uuid,boolean,uuid,text),public.avatar_cleanup_inventory(integer,text),
 public.avatar_cleanup_adopt(jsonb),public.avatar_cleanup_set_enabled(boolean),public.avatar_cleanup_claim(integer),
 public.avatar_cleanup_prepare(text,uuid),public.avatar_cleanup_finish(text,uuid,boolean) to service_role;
-- Service-only INVOKER RPCs need their private helpers; never grant them to clients.
grant execute on function private.avatar_path_known(text),private.avatar_path_lock(text),private.avatar_known_owner(uuid),
 private.avatar_account_deletion(uuid),private.avatar_protected(text),private.avatar_begin(text,text,uuid) to service_role;
