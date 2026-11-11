-- Historical actors remain profile identities after Auth hard deletion.
alter table public.messages drop constraint messages_actor_user_id_fkey;
alter table public.messages add constraint messages_actor_user_id_fkey foreign key(actor_user_id) references public.profiles(id);
alter table private.admin_audit drop constraint admin_audit_actor_user_id_fkey;
alter table private.admin_audit add constraint admin_audit_actor_user_id_fkey foreign key(actor_user_id) references public.profiles(id);
alter table private.connection_removals drop constraint connection_removals_actor_user_id_fkey;
alter table private.connection_removals add constraint connection_removals_actor_user_id_fkey foreign key(actor_user_id) references public.profiles(id);
alter table private.push_subscriptions drop constraint push_subscriptions_user_id_fkey;
alter table private.push_subscriptions add constraint push_subscriptions_user_id_fkey foreign key(user_id) references public.profiles(id);
alter table private.push_subscriptions alter column endpoint drop not null,alter column endpoint_hash drop not null,
  alter column p256dh drop not null,alter column auth drop not null;
alter table public.profiles drop constraint profiles_identity_check;
alter table public.profiles add constraint profiles_identity_check check(
  (profile_kind='member' and disabled_at is null and
    ((deleted_at is null and auth_user_id is not null and id=auth_user_id) or (deleted_at is not null and auth_user_id is null)))
  or (profile_kind='managed' and auth_user_id is null)
);
alter table public.profiles drop constraint profiles_summary_check;
alter table public.profiles add constraint profiles_summary_check check(
  (deleted_at is not null and summary='') or (deleted_at is null and length(btrim(summary))>=1 and octet_length(summary)<=32768)
);
alter table public.profiles add constraint profiles_deleted_data_check check(deleted_at is null or(
  name='Удалённый пользователь' and occupation='' and summary='' and cardinality(skills)=0
  and cardinality(searching_skills)=0 and avatar_path is null and auth_user_id is null
));

create table private.account_deletions (
  operation_id uuid primary key,
  actor_profile_id uuid not null references public.profiles(id),
  target_profile_id uuid not null unique references public.profiles(id),
  kind text not null check(kind in('account','managed')),
  receipt_hash text,
  request jsonb not null,
  auth_user_id uuid,
  state text not null default 'pending' check(state in('pending','leased','complete')),
  requested_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  next_attempt_at timestamptz not null default clock_timestamp(),
  attempts bigint not null default 0 check(attempts>=0),
  lease_token uuid,
  lease_until timestamptz,
  last_error text check(last_error in('storage_unavailable','auth_unavailable','cleanup_pending','server_unavailable')),
  check((kind='account' and receipt_hash is not null and receipt_hash ~ '^[a-f0-9]{64}$' and auth_user_id is not null)
    or (kind='managed' and receipt_hash is null and auth_user_id is null)),
  check((state='complete')=(completed_at is not null)),
  check((state='leased' and lease_token is not null and lease_until is not null)
    or (state<>'leased' and lease_token is null and lease_until is null))
);
create index account_deletions_pending_idx on private.account_deletions(next_attempt_at,operation_id) where state<>'complete';
alter table private.account_deletions enable row level security;
revoke all on private.account_deletions from public,anon,authenticated;
grant all on private.account_deletions to service_role;

create function private.require_auth_session(p_user uuid,p_session uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not private.push_session_active(p_user,p_session) then raise exception 'session_revoked'; end if;
end;
$$;
create function public.member_require_auth_session(p_user uuid,p_session uuid) returns void
language sql stable set search_path = '' as $$
  select private.require_auth_session(p_user,p_session);
$$;

-- Access checks also cover still-valid JWTs while external cleanup retries.
create function private.avatar_owner_access() returns boolean
language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null
    and not exists(select 1 from public.profiles where id=auth.uid() and deleted_at is not null)
    and not exists(select 1 from private.account_deletions where target_profile_id=auth.uid() and kind='account');
$$;
create function private.guard_avatar_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target text; removed_at timestamptz;
begin
  if new.bucket_id<>'avatars' then return new; end if;
  target:=split_part(new.name,'/',1);
  if target !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' then return new; end if;
  select deleted_at into removed_at from public.profiles where id=target::uuid for share;
  if found and removed_at is not null then raise exception 'profile_unavailable'; end if;
  return new;
end;
$$;
create trigger guard_deleted_avatar before insert or update on storage.objects for each row execute function private.guard_avatar_profile();
drop policy avatar_owner_read on storage.objects;
drop policy avatar_insert on storage.objects;
drop policy avatar_update on storage.objects;
drop policy avatar_owner_delete on storage.objects;
create policy avatar_owner_read on storage.objects for select to authenticated
  using(bucket_id='avatars' and name ~ ('^'||(select auth.uid())::text||'/[a-f0-9]{64}[.]png$') and private.avatar_owner_access());
create policy avatar_insert on storage.objects for insert to authenticated
  with check(bucket_id='avatars' and name ~ ('^'||(select auth.uid())::text||'/[a-f0-9]{64}[.]png$') and private.avatar_owner_access());
create policy avatar_update on storage.objects for update to authenticated
  using(bucket_id='avatars' and name ~ ('^'||(select auth.uid())::text||'/[a-f0-9]{64}[.]png$') and private.avatar_owner_access())
  with check(bucket_id='avatars' and name ~ ('^'||(select auth.uid())::text||'/[a-f0-9]{64}[.]png$') and private.avatar_owner_access());
create policy avatar_owner_delete on storage.objects for delete to authenticated
  using(bucket_id='avatars' and name ~ ('^'||(select auth.uid())::text||'/[a-f0-9]{64}[.]png$') and private.avatar_owner_access());

create function private.deletion_result(p_job private.account_deletions) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('operation_id',p_job.operation_id,'state',case when p_job.state='complete' then 'complete' else 'pending' end);
$$;
create function public.account_deletion_status(p_operation uuid,p_receipt_hash text) returns jsonb
language sql stable set search_path = '' as $$
  select private.deletion_result(j) from private.account_deletions j
  where operation_id=p_operation and kind='account' and receipt_hash=p_receipt_hash;
$$;

create function private.start_profile_deletion(p_actor uuid,p_session uuid,p_profile uuid,p_operation uuid,
  p_kind text,p_receipt_hash text,p_expected_updated_at timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare previous private.account_deletions; target public.profiles; expected jsonb; counterpart record;
begin
  if p_operation is null or p_profile is null or p_actor is null or p_kind is null or p_kind not in('account','managed')
    or (p_kind='account' and (p_profile<>p_actor or p_receipt_hash is null or p_receipt_hash !~ '^[a-f0-9]{64}$'))
    or (p_kind='managed' and p_receipt_hash is not null) then raise exception 'invalid_request'; end if;
  expected:=jsonb_build_object('kind',p_kind,'profile_id',p_profile,'expected_updated_at',p_expected_updated_at);
  perform pg_advisory_xact_lock(hashtextextended(p_operation::text,72));
  select * into previous from private.account_deletions where operation_id=p_operation;
  if found then
    if previous.actor_profile_id<>p_actor or previous.target_profile_id<>p_profile or previous.kind<>p_kind
      or previous.request is distinct from expected or previous.receipt_hash is distinct from p_receipt_hash then
      raise exception 'operation_id_conflict';
    end if;
    if p_kind='managed' then perform private.require_member_session(p_actor,p_session); end if;
    return private.deletion_result(previous);
  end if;
  perform private.require_member_session(p_actor,p_session);
  if p_kind='account' then
    perform pg_advisory_xact_lock(hashtextextended(p_actor::text,0));
    select * into target from public.profiles where id=p_actor for update;
    if not found or target.deleted_at is not null or target.auth_user_id is distinct from p_actor then raise exception 'account_deleted'; end if;
  else
    perform private.require_admin(p_actor);
    perform pg_advisory_xact_lock(hashtextextended(p_actor::text||p_operation::text,43));
    perform pg_advisory_xact_lock(hashtextextended(p_profile::text,43));
    perform private.require_managed_profile(p_actor,p_profile);
    select * into target from public.profiles where id=p_profile for update;
    if p_expected_updated_at is null or target.updated_at<>p_expected_updated_at then raise exception 'profile_version_conflict'; end if;
  end if;
  if exists(select 1 from private.admin_audit where actor_user_id=p_actor and client_operation_id=p_operation) then
    raise exception 'operation_id_conflict';
  end if;
  insert into private.account_deletions(operation_id,actor_profile_id,target_profile_id,kind,receipt_hash,request,auth_user_id)
    values(p_operation,p_actor,p_profile,p_kind,p_receipt_hash,expected,case when p_kind='account' then p_actor else null end)
    returning * into previous;
  if to_regprocedure('private.community_remove_for_author(uuid)') is not null then
    perform private.community_remove_for_author(p_profile);
  end if;
  if to_regclass('private.phone_discovery_settings') is not null then
    delete from private.phone_discovery_settings where user_id=p_profile;
  end if;
  -- Existing conversations refresh even when the former connection was removed.
  for counterpart in
    select c.id conversation_id,p.id,p.auth_user_id from public.conversations c
      join public.profiles p on p.id=case when c.user_low=p_profile then c.user_high else c.user_low end
    where (c.user_low=p_profile or c.user_high=p_profile) and c.last_message_seq>0
      and p.deleted_at is null and p.disabled_at is null
  loop
    if counterpart.auth_user_id is not null then
      perform realtime.send(jsonb_build_object('conversation_id',counterpart.conversation_id,'profile_changed',true),
        'changed','chat:user:'||counterpart.auth_user_id::text,true);
    else
      perform private.notify_managed_operators(counterpart.id);
    end if;
  end loop;
  delete from public.connections where user_low=p_profile or user_high=p_profile;
  delete from private.invitations where issuer_id=p_profile;
  delete from private.managed_profile_grants where profile_id=p_profile or user_id=p_profile;
  update private.managed_profile_grants set granted_by=null where granted_by=p_profile;
  update private.admin_roles set granted_by=null where granted_by=p_profile;
  delete from private.managed_profile_reservations where actor_user_id=p_profile;
  delete from private.admin_roles where user_id=p_profile;
  update private.notification_jobs set push_expanded_at=coalesce(push_expanded_at,clock_timestamp())
    where recipient_user_id=p_profile or conversation_id in(select id from public.conversations where user_low=p_profile or user_high=p_profile);
  update private.push_deliveries set status='cancelled',lease_token=null,lease_until=null
    where status in('pending','leased') and (job_id in(select id from private.notification_jobs
      where recipient_user_id=p_profile or conversation_id in(select id from public.conversations where user_low=p_profile or user_high=p_profile))
      or binding_id in(select binding_id from private.push_subscriptions where user_id=p_profile));
  update private.push_subscriptions set disabled_at=coalesce(disabled_at,clock_timestamp()),endpoint=null,endpoint_hash=null,
    p256dh=null,auth=null,session_id='00000000-0000-0000-0000-000000000000' where user_id=p_profile;
  update private.admin_audit set details=jsonb_build_object('redacted',true) where profile_id=p_profile;
  update public.profiles set name='Удалённый пользователь',occupation='',summary='',skills='{}',searching_skills='{}',avatar_path=null,
    auth_user_id=null,deleted_at=clock_timestamp(),disabled_at=case when profile_kind='managed' then coalesce(disabled_at,clock_timestamp()) else null end,
    updated_at=clock_timestamp() where id=p_profile;
  delete from private.memberships where user_id=p_profile;
  if p_kind='account' then delete from auth.sessions where user_id=p_actor; end if;
  insert into private.admin_audit(actor_user_id,profile_id,action,client_operation_id,details)
    values(p_actor,p_profile,case when p_kind='account' then 'account_delete' else 'profile_delete' end,p_operation,
      jsonb_build_object('request',expected,'result',private.deletion_result(previous)));
  return private.deletion_result(previous);
end;
$$;

create function public.member_delete_account(p_user uuid,p_session uuid,p_expected_user uuid,p_operation uuid,p_receipt_hash text) returns jsonb
language plpgsql set search_path = '' as $$
begin
  if p_expected_user is distinct from p_user then raise exception 'identity_changed'; end if;
  return private.start_profile_deletion(p_user,p_session,p_user,p_operation,'account',p_receipt_hash,null);
end;
$$;
create function public.admin_delete_profile(p_actor uuid,p_session uuid,p_profile uuid,p_client_operation uuid,p_expected_updated_at timestamptz) returns jsonb
language sql set search_path = '' as $$
  select private.start_profile_deletion(p_actor,p_session,p_profile,p_client_operation,'managed',null,p_expected_updated_at);
$$;

create function public.account_cleanup_claim(p_operation uuid default null,p_limit integer default 2) returns jsonb
language plpgsql set search_path = '' set statement_timeout='8s' as $$
declare job private.account_deletions; fence uuid; result jsonb:='[]'::jsonb;
begin
  if p_limit is null or p_limit<1 or p_limit>4 then raise exception 'invalid_request'; end if;
  for job in select * from private.account_deletions
    where (p_operation is null or operation_id=p_operation)
      and ((state='pending' and next_attempt_at<=clock_timestamp()) or (state='leased' and lease_until<=clock_timestamp()))
    order by next_attempt_at,operation_id for update skip locked limit p_limit loop
    fence:=gen_random_uuid();
    update private.account_deletions set state='leased',lease_token=fence,lease_until=clock_timestamp()+interval '60 seconds',attempts=attempts+1
      where operation_id=job.operation_id;
    result:=result||jsonb_build_array(jsonb_build_object('operation_id',job.operation_id,'lease_token',fence));
  end loop;
  return result;
end;
$$;
create function public.account_cleanup_prepare(p_operation uuid,p_lease uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare job private.account_deletions; objects jsonb;
begin
  select * into job from private.account_deletions where operation_id=p_operation for update;
  if not found or p_lease is null or job.state<>'leased' or job.lease_token is distinct from p_lease
    or job.lease_until is null or job.lease_until<=clock_timestamp() then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket_id,'name',name)),'[]'::jsonb) into objects from(
    select bucket_id,name from storage.objects where
      (job.auth_user_id is not null and owner_id=job.auth_user_id::text)
      or (bucket_id='avatars' and starts_with(name,job.target_profile_id::text||'/'))
    order by bucket_id,name limit 100
  ) files;
  update private.account_deletions set lease_until=clock_timestamp()+interval '60 seconds' where operation_id=p_operation;
  return jsonb_build_object('objects',objects,'auth_user_id',job.auth_user_id);
end;
$$;
create function private.finish_account_cleanup(p_operation uuid,p_lease uuid,p_success boolean,p_error text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare job private.account_deletions; done boolean;
begin
  select * into job from private.account_deletions where operation_id=p_operation for update;
  if not found or p_lease is null or job.state<>'leased' or job.lease_token is distinct from p_lease
    or job.lease_until is null or job.lease_until<=clock_timestamp() then return null; end if;
  if p_error is not null and p_error not in('storage_unavailable','auth_unavailable','cleanup_pending','server_unavailable') then raise exception 'invalid_request'; end if;
  done:=p_success is true and not exists(select 1 from storage.objects where
    (job.auth_user_id is not null and owner_id=job.auth_user_id::text)
      or (bucket_id='avatars' and starts_with(name,job.target_profile_id::text||'/')))
    and (job.auth_user_id is null or not exists(select 1 from auth.users where id=job.auth_user_id));
  update private.account_deletions set state=case when done then 'complete' else 'pending' end,
    completed_at=case when done then clock_timestamp() else null end,lease_token=null,lease_until=null,
    last_error=case when done then null else coalesce(p_error,'cleanup_pending') end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>least(30*power(2,least(attempts-1,7))::integer,3600))
    where operation_id=p_operation returning * into job;
  return private.deletion_result(job);
end;
$$;
create function public.account_cleanup_finish(p_operation uuid,p_lease uuid,p_success boolean,p_error text default null) returns jsonb
language sql set search_path = '' as $$
  select private.finish_account_cleanup(p_operation,p_lease,p_success,p_error);
$$;

revoke all on function private.require_auth_session(uuid,uuid),public.member_require_auth_session(uuid,uuid),
  private.deletion_result(private.account_deletions),public.account_deletion_status(uuid,text),
  private.start_profile_deletion(uuid,uuid,uuid,uuid,text,text,timestamptz),public.member_delete_account(uuid,uuid,uuid,uuid,text),
  public.admin_delete_profile(uuid,uuid,uuid,uuid,timestamptz),public.account_cleanup_claim(uuid,integer),
  public.account_cleanup_prepare(uuid,uuid),private.finish_account_cleanup(uuid,uuid,boolean,text),public.account_cleanup_finish(uuid,uuid,boolean,text),
  private.avatar_owner_access(),private.guard_avatar_profile() from public,anon,authenticated;
grant execute on function private.require_auth_session(uuid,uuid),public.member_require_auth_session(uuid,uuid),
  private.deletion_result(private.account_deletions),public.account_deletion_status(uuid,text),
  private.start_profile_deletion(uuid,uuid,uuid,uuid,text,text,timestamptz),public.member_delete_account(uuid,uuid,uuid,uuid,text),
  public.admin_delete_profile(uuid,uuid,uuid,uuid,timestamptz),public.account_cleanup_claim(uuid,integer),
  public.account_cleanup_prepare(uuid,uuid),private.finish_account_cleanup(uuid,uuid,boolean,text),public.account_cleanup_finish(uuid,uuid,boolean,text)
  to service_role;
grant execute on function private.avatar_owner_access() to authenticated;


create or replace function private.require_admin(p_actor uuid) returns text
language plpgsql set search_path = '' as $$
declare assigned_role text;
begin
  perform 1 from public.profiles p join private.memberships m on m.user_id=p.id
    where p.id=p_actor and p.auth_user_id=p_actor and p.profile_kind='member' and p.deleted_at is null for share of p;
  if not found then raise exception 'admin_forbidden'; end if;
  select role into assigned_role from private.admin_roles where user_id=p_actor and revoked_at is null for share;
  if not found then raise exception 'admin_forbidden'; end if;
  return assigned_role;
end;
$$;

create or replace function private.require_managed_profile(p_actor uuid,p_profile uuid,p_reply boolean default false)
returns void language plpgsql set search_path = '' as $$
begin
  perform private.require_admin(p_actor);
  -- Fixed role -> grant -> profile order also serializes disable/edit/reply.
  perform 1 from private.managed_profile_grants g
    where g.user_id=p_actor and g.profile_id=p_profile and g.revoked_at is null
      and (case when p_reply then g.can_reply else g.can_manage end) for share;
  if not found then raise exception 'managed_profile_forbidden'; end if;
  perform 1 from public.profiles p where p.id=p_profile and p.profile_kind='managed' and p.deleted_at is null
    and (not p_reply or p.disabled_at is null) for update;
  if not found then raise exception 'managed_profile_forbidden'; end if;
end;
$$;

create or replace function private.require_operator_profile(p_actor uuid,p_profile uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform private.require_admin(p_actor);
  perform 1 from private.managed_profile_grants where user_id=p_actor and profile_id=p_profile
    and can_reply and revoked_at is null for share;
  if not found then raise exception 'managed_profile_forbidden'; end if;
  perform 1 from public.profiles where id=p_profile and profile_kind='managed' and deleted_at is null for share;
  if not found then raise exception 'managed_profile_forbidden'; end if;
end;
$$;

create or replace function private.save_profile(member_id uuid, draft jsonb) returns void
language plpgsql set search_path = '' as $$
declare offered text[]; searching text[]; avatar text; legacy_count integer; removed_at timestamptz;
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
  select cardinality(skills),deleted_at into legacy_count,removed_at from public.profiles where id=member_id for update;
  if removed_at is not null or exists(select 1 from private.account_deletions where target_profile_id=member_id and kind='account') then
    raise exception 'account_deleted';
  end if;
  if cardinality(offered)>greatest(5,coalesce(legacy_count,0))
    and private.invited_registration_count(member_id)<10 then raise exception 'offering_limit_reached'; end if;
  avatar := nullif(draft->>'avatar_path', '');
  if avatar is not null and not private.owns_avatar(member_id, avatar) then raise exception 'invalid_profile'; end if;
  insert into public.profiles(id, name, occupation, summary, skills, searching_skills, avatar_path)
  values(member_id, btrim(draft->>'name'), coalesce(btrim(draft->>'occupation'), ''), btrim(draft->>'summary'), offered, searching, avatar)
  on conflict(id) do update set name = excluded.name, occupation = excluded.occupation,
    summary = excluded.summary, skills = excluded.skills, searching_skills = excluded.searching_skills,
    avatar_path = excluded.avatar_path, updated_at = clock_timestamp();
end;
$$;

create or replace function public.redeem_invitation(p_user uuid, p_hash text, p_manual boolean, p_profile jsonb)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.invitations; already_member boolean; locked_issuer uuid;
begin
  -- A per-user lock serializes first registration with different invitations.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text, 0));
  if exists(select 1 from public.profiles where id=p_user and deleted_at is not null)
    or exists(select 1 from private.account_deletions where target_profile_id=p_user and kind='account') then raise exception 'account_deleted'; end if;
  select * into item from private.invitations where (not p_manual and token_hash=p_hash) or (p_manual and code_hash=p_hash);
  if not found then raise exception 'invalid_invitation'; end if;
  if item.issuer_id=p_user then raise exception 'own_invitation'; end if;
  locked_issuer:=item.issuer_id;
  if locked_issuer is not null then
    perform 1 from public.profiles p join private.memberships m on m.user_id=p.id
      where p.id=locked_issuer and p.auth_user_id=p.id and p.deleted_at is null and p.disabled_at is null for share of p;
    if not found then raise exception 'invalid_invitation'; end if;
  end if;
  select * into item from private.invitations where (not p_manual and token_hash=p_hash) or (p_manual and code_hash=p_hash) for update;
  if not found or item.issuer_id is distinct from locked_issuer then raise exception 'invalid_invitation'; end if;
  if exists(select 1 from private.invite_redemptions where invitation_id = item.id and user_id = p_user) then
    return jsonb_build_object('connected', item.issuer_id is not null and exists(
      select 1 from public.connections where user_low=least(p_user,item.issuer_id) and user_high=greatest(p_user,item.issuer_id)
    ), 'replayed', true);
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
    if item.issuer_id is not null then
      insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
        values(p_user,item.issuer_id,clock_timestamp()) on conflict do nothing;
    end if;
  end if;
  if item.issuer_id is not null then
    -- The same pair lock as chat_send/chat_disconnect serializes explicit re-invites.
    perform pg_advisory_xact_lock(hashtextextended(least(p_user,item.issuer_id)::text || greatest(p_user,item.issuer_id)::text,10));
    insert into public.connections(user_low, user_high)
      values(least(p_user, item.issuer_id), greatest(p_user, item.issuer_id)) on conflict do nothing;
  end if;
  insert into private.invite_redemptions(invitation_id, user_id) values(item.id, p_user);
  update private.invitations set uses = uses + 1 where id = item.id;
  return jsonb_build_object('connected', item.issuer_id is not null, 'replayed', false);
end;
$$;

create or replace function public.issue_invitation(p_user uuid, p_token_hash text, p_code_hash text)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.invitations; issued_at timestamptz;
begin
  perform 1 from public.profiles where id=p_user and auth_user_id=p_user and deleted_at is null for share;
  if not found then raise exception 'membership_required'; end if;
  perform 1 from private.memberships where user_id = p_user for update;
  if not found then raise exception 'membership_required'; end if;
  -- Retrying the same issuance never extends its original lifetime.
  select * into item from private.invitations where token_hash = p_token_hash and issuer_id = p_user;
  if not found then
    if (select count(*) from private.invitations where issuer_id = p_user and created_at > clock_timestamp() - interval '1 minute') >= 5 then
      raise exception 'rate_limited';
    end if;
    update private.invitations set code_hash = null where expires_at <= clock_timestamp() and code_hash is not null;
    issued_at := clock_timestamp();
    insert into private.invitations(issuer_id, token_hash, code_hash, created_at, expires_at)
      values(p_user, p_token_hash, p_code_hash, issued_at, issued_at + interval '15 minutes') returning * into item;
  end if;
  if item.revoked_at is not null or item.expires_at <= clock_timestamp() then raise exception 'invalid_invitation'; end if;
  return jsonb_build_object('id', item.id, 'expires_at', item.expires_at, 'server_now', clock_timestamp());
end;
$$;

create or replace function public.admin_save_profile(p_actor uuid,p_profile uuid,p_create boolean,p_client_operation uuid,
  p_draft jsonb,p_expected_updated_at timestamptz default null) returns jsonb
language plpgsql set search_path = '' as $$
declare previous private.admin_audit; item public.profiles; offered text[]; searching text[];
  avatar text; request jsonb; result jsonb;
begin
  perform public.admin_authorize_save(p_actor,p_profile,p_create,p_client_operation);
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text || p_client_operation::text,43));
  perform pg_advisory_xact_lock(hashtextextended(p_profile::text,43));
  if exists(select 1 from public.profiles where id=p_profile and deleted_at is not null) then raise exception 'managed_profile_forbidden'; end if;
  request:=jsonb_build_object('create',p_create,'draft',p_draft,'expected_updated_at',p_expected_updated_at);
  select * into previous from private.admin_audit where actor_user_id=p_actor and client_operation_id=p_client_operation;
  if found then
    if previous.profile_id<>p_profile or previous.action<>(case when p_create then 'profile_create' else 'profile_edit' end)
      or previous.details->'request'<>request then raise exception 'operation_id_conflict'; end if;
    return previous.details->'result' || jsonb_build_object('replayed',true);
  end if;
  select * into item from public.profiles where id=p_profile for update;
  if p_create and found then raise exception 'managed_profile_forbidden'; end if;
  if not p_create and (not found or p_expected_updated_at is null or item.updated_at<>p_expected_updated_at) then
    raise exception 'profile_version_conflict';
  end if;
  if p_draft is null or jsonb_typeof(p_draft)<>'object'
    or jsonb_typeof(p_draft->'name') is distinct from 'string'
    or jsonb_typeof(p_draft->'occupation') is distinct from 'string'
    or jsonb_typeof(p_draft->'summary') is distinct from 'string'
    or jsonb_typeof(p_draft->'skills') is distinct from 'array'
    or jsonb_typeof(p_draft->'searching_skills') is distinct from 'array'
    or length(btrim(p_draft->>'name'))<1 or octet_length(p_draft->>'name')>32768
    or length(btrim(p_draft->>'summary'))<1 or octet_length(p_draft->>'summary')>32768
    or octet_length(p_draft->>'occupation')>32768
    or exists(select 1 from jsonb_object_keys(p_draft) k where k not in ('name','occupation','summary','skills','searching_skills','avatar_path')) then
    raise exception 'invalid_profile';
  end if;
  if exists(select 1 from jsonb_array_elements(p_draft->'skills') s where jsonb_typeof(s)<>'string')
    or exists(select 1 from jsonb_array_elements(p_draft->'searching_skills') s where jsonb_typeof(s)<>'string') then
    raise exception 'invalid_profile';
  end if;
  offered:=array(select jsonb_array_elements_text(p_draft->'skills'));
  searching:=array(select jsonb_array_elements_text(p_draft->'searching_skills'));
  if not private.valid_skills(offered,true) or not private.valid_skills(searching,false) then raise exception 'invalid_profile'; end if;
  avatar:=nullif(p_draft->>'avatar_path','');
  if avatar is not null and (avatar !~ ('^' || p_profile::text || '/[a-f0-9]{64}[.]png$')
    or not exists(select 1 from storage.objects where bucket_id='avatars' and name=avatar)) then raise exception 'invalid_profile'; end if;
  if p_create then
    insert into public.profiles(id,profile_kind,name,occupation,summary,skills,searching_skills,avatar_path)
      values(p_profile,'managed',btrim(p_draft->>'name'),btrim(p_draft->>'occupation'),btrim(p_draft->>'summary'),offered,searching,avatar)
      returning * into item;
    insert into private.managed_profile_grants(user_id,profile_id,can_manage,can_reply,granted_by)
      values(p_actor,p_profile,true,true,p_actor);
  else
    update public.profiles set name=btrim(p_draft->>'name'),occupation=btrim(p_draft->>'occupation'),
      summary=btrim(p_draft->>'summary'),skills=offered,searching_skills=searching,avatar_path=avatar,updated_at=clock_timestamp()
      where id=p_profile returning * into item;
  end if;
  result:=jsonb_build_object('profile',to_jsonb(item),'replayed',false);
  insert into private.admin_audit(actor_user_id,profile_id,action,client_operation_id,details)
    values(p_actor,p_profile,case when p_create then 'profile_create' else 'profile_edit' end,p_client_operation,
      jsonb_build_object('request',request,'result',result));
  return result;
end;
$$;

create or replace function public.chat_list(p_user uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare result jsonb;
begin
  perform private.require_chat_member(p_user,null);
  select coalesce(jsonb_agg(row_data order by changed desc, conversation_id), '[]'::jsonb) into result
  from (
    select c.id conversation_id,c.updated_at changed,
      to_jsonb(c) || jsonb_build_object(
        'peer',jsonb_build_object('id',p.id,'name',p.name,'occupation',p.occupation,'avatar_path',p.avatar_path,'deleted_at',p.deleted_at),
        'last_read_seq',m.last_read_seq,
        'unread_count',(select count(*) from public.messages x where x.conversation_id=c.id and x.seq>m.last_read_seq and x.sender_profile_id<>p_user),
        'last_message',(select to_jsonb(x) from public.messages x where x.conversation_id=c.id order by x.seq desc limit 1)
      ) row_data
    from public.conversation_members m join public.conversations c on c.id=m.conversation_id
    join public.profiles p on p.id=case when c.user_low=p_user then c.user_high else c.user_low end
    where m.user_id=p_user and c.last_message_seq>0
  ) rows;
  return jsonb_build_object('conversations',result);
end;
$$;

create or replace function public.operator_inbox(p_actor uuid,p_profile uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare result jsonb;
begin
  perform private.require_operator_profile(p_actor,p_profile);
  select coalesce(jsonb_agg(row_data order by changed desc,conversation_id),'[]'::jsonb) into result from (
    select c.id conversation_id,c.updated_at changed,to_jsonb(c) || jsonb_build_object(
      'peer',jsonb_build_object('id',p.id,'name',p.name,'occupation',p.occupation,'avatar_path',null,'deleted_at',p.deleted_at),
      'last_read_seq',m.last_read_seq,
      'unread_count',(select count(*) from public.messages x where x.conversation_id=c.id and x.seq>m.last_read_seq and x.sender_profile_id<>p_profile),
      'last_message',(select to_jsonb(x) from public.messages x where x.conversation_id=c.id order by x.seq desc limit 1)) row_data
    from public.conversation_members m join public.conversations c on c.id=m.conversation_id
    join public.profiles p on p.id=case when c.user_low=p_profile then c.user_high else c.user_low end
    where m.user_id=p_profile and c.last_message_seq>0
  ) rows;
  return jsonb_build_object('conversations',result,'profile_disabled',(select disabled_at is not null from public.profiles where id=p_profile));
end;
$$;
