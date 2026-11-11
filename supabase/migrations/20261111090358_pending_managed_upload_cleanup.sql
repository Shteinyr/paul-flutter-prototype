-- Preserve the unpublished upload prefixes before removing their reservations.
-- Existing managed profiles retain independent ownership and their files.
alter table private.account_deletions add column abandoned_profile_ids uuid[] not null default '{}';

create or replace function private.guard_avatar_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
declare target text; removed_at timestamptz; creator uuid;
begin
  if new.bucket_id<>'avatars' then return new; end if;
  target:=split_part(new.name,'/',1);
  if target !~ '^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$' then return new; end if;
  select deleted_at into removed_at from public.profiles where id=target::uuid for share;
  if found then
    if removed_at is not null then raise exception 'profile_unavailable'; end if;
    return new;
  end if;
  -- New members upload before registration. A managed draft instead requires
  -- its current reservation and a live admin, locked before account deletion.
  perform 1 from auth.users where id=target::uuid for key share;
  if found then return new; end if;
  select actor_user_id into creator from private.managed_profile_reservations where profile_id=target::uuid;
  if found then perform 1 from public.profiles where id=creator for share; end if;
  -- Creation may have published the profile while this upload waited for the
  -- creator lock. That independent profile remains valid after creator deletion.
  select deleted_at into removed_at from public.profiles where id=target::uuid for share;
  if found then
    if removed_at is not null then raise exception 'profile_unavailable'; end if;
    return new;
  end if;
  if creator is null then raise exception 'profile_unavailable'; end if;
  perform private.require_admin(creator);
  perform 1 from private.managed_profile_reservations where profile_id=target::uuid and actor_user_id=creator for share;
  if found then return new; end if;
  select deleted_at into removed_at from public.profiles where id=target::uuid for share;
  if found and removed_at is null then return new; end if;
  raise exception 'profile_unavailable';
end;
$$;

create or replace function private.start_profile_deletion(p_actor uuid,p_session uuid,p_profile uuid,p_operation uuid,
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
  insert into private.account_deletions(operation_id,actor_profile_id,target_profile_id,kind,receipt_hash,request,auth_user_id,abandoned_profile_ids)
    values(p_operation,p_actor,p_profile,p_kind,p_receipt_hash,expected,case when p_kind='account' then p_actor else null end,
      case when p_kind='account' then array(select r.profile_id from private.managed_profile_reservations r
        where r.actor_user_id=p_actor and not exists(select 1 from public.profiles p where p.id=r.profile_id)) else '{}'::uuid[] end)
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

create or replace function public.account_cleanup_prepare(p_operation uuid,p_lease uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare job private.account_deletions; objects jsonb;
begin
  select * into job from private.account_deletions where operation_id=p_operation for update;
  if not found or p_lease is null or job.state<>'leased' or job.lease_token is distinct from p_lease
    or job.lease_until is null or job.lease_until<=clock_timestamp() then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('bucket',bucket_id,'name',name)),'[]'::jsonb) into objects from(
    select bucket_id,name from storage.objects where
      (job.auth_user_id is not null and owner_id=job.auth_user_id::text)
      or (bucket_id='avatars' and lower(split_part(name,'/',1)) in(select id::text from unnest(array_prepend(job.target_profile_id,job.abandoned_profile_ids)) id))
    order by bucket_id,name limit 100
  ) files;
  update private.account_deletions set lease_until=clock_timestamp()+interval '60 seconds' where operation_id=p_operation;
  return jsonb_build_object('objects',objects,'auth_user_id',job.auth_user_id);
end;
$$;

create or replace function private.finish_account_cleanup(p_operation uuid,p_lease uuid,p_success boolean,p_error text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare job private.account_deletions; done boolean;
begin
  select * into job from private.account_deletions where operation_id=p_operation for update;
  if not found or p_lease is null or job.state<>'leased' or job.lease_token is distinct from p_lease
    or job.lease_until is null or job.lease_until<=clock_timestamp() then return null; end if;
  if p_error is not null and p_error not in('storage_unavailable','auth_unavailable','cleanup_pending','server_unavailable') then raise exception 'invalid_request'; end if;
  done:=p_success is true and not exists(select 1 from storage.objects where
    (job.auth_user_id is not null and owner_id=job.auth_user_id::text)
      or (bucket_id='avatars' and lower(split_part(name,'/',1)) in(select id::text from unnest(array_prepend(job.target_profile_id,job.abandoned_profile_ids)) id)))
    and (job.auth_user_id is null or not exists(select 1 from auth.users where id=job.auth_user_id));
  update private.account_deletions set state=case when done then 'complete' else 'pending' end,
    completed_at=case when done then clock_timestamp() else null end,lease_token=null,lease_until=null,
    last_error=case when done then null else coalesce(p_error,'cleanup_pending') end,
    next_attempt_at=clock_timestamp()+make_interval(secs=>least(30*power(2,least(attempts-1,7))::integer,3600))
    where operation_id=p_operation returning * into job;
  return private.deletion_result(job);
end;
$$;
