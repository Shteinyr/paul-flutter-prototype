create table private.managed_profile_reservations (
  actor_user_id uuid not null references auth.users(id),
  client_operation_id uuid not null,
  profile_id uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default clock_timestamp(),
  primary key(actor_user_id,client_operation_id)
);
alter table private.managed_profile_reservations enable row level security;
revoke all on private.managed_profile_reservations from public,anon,authenticated;
grant all on private.managed_profile_reservations to service_role;

create function public.admin_prepare_create(p_actor uuid,p_client_operation uuid) returns uuid
language plpgsql set search_path = '' as $$
declare reserved uuid;
begin
  perform private.require_admin(p_actor);
  if p_client_operation is null then raise exception 'invalid_request'; end if;
  insert into private.managed_profile_reservations(actor_user_id,client_operation_id)
    values(p_actor,p_client_operation) on conflict(actor_user_id,client_operation_id) do nothing;
  select profile_id into reserved from private.managed_profile_reservations
    where actor_user_id=p_actor and client_operation_id=p_client_operation;
  return reserved;
end;
$$;

-- All command identities come from Auth.getUser in the administrative Edge.
-- The operation journal and profile write commit together, including failures.
create or replace function public.admin_authorize_save(p_actor uuid,p_profile uuid,p_create boolean,p_client_operation uuid)
returns void language plpgsql set search_path = '' as $$
begin
  perform private.require_admin(p_actor);
  if p_profile is null or p_create is null or p_client_operation is null then raise exception 'invalid_request'; end if;
  if p_create and (exists(select 1 from auth.users where id=p_profile) or not exists(
    select 1 from private.managed_profile_reservations where actor_user_id=p_actor and client_operation_id=p_client_operation and profile_id=p_profile
  )) then raise exception 'managed_profile_forbidden'; end if;
  if not p_create or exists(select 1 from public.profiles where id=p_profile) then
    perform private.require_managed_profile(p_actor,p_profile);
    if p_create and not exists(select 1 from private.admin_audit where actor_user_id=p_actor
      and client_operation_id=p_client_operation and profile_id=p_profile and action='profile_create') then
      raise exception 'managed_profile_forbidden';
    end if;
  end if;
end;
$$;

create function public.admin_save_profile(p_actor uuid,p_profile uuid,p_create boolean,p_client_operation uuid,
  p_draft jsonb,p_expected_updated_at timestamptz default null) returns jsonb
language plpgsql set search_path = '' as $$
declare previous private.admin_audit; item public.profiles; offered text[]; searching text[];
  avatar text; request jsonb; result jsonb;
begin
  perform public.admin_authorize_save(p_actor,p_profile,p_create,p_client_operation);
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text || p_client_operation::text,43));
  perform pg_advisory_xact_lock(hashtextextended(p_profile::text,43));
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

create function public.admin_set_profile_enabled(p_actor uuid,p_profile uuid,p_enabled boolean,
  p_client_operation uuid,p_expected_updated_at timestamptz) returns jsonb
language plpgsql set search_path = '' as $$
declare previous private.admin_audit; item public.profiles; request jsonb; result jsonb;
begin
  perform private.require_managed_profile(p_actor,p_profile);
  if p_enabled is null or p_client_operation is null then raise exception 'invalid_request'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text || p_client_operation::text,43));
  perform pg_advisory_xact_lock(hashtextextended(p_profile::text,43));
  request:=jsonb_build_object('enabled',p_enabled,'expected_updated_at',p_expected_updated_at);
  select * into previous from private.admin_audit where actor_user_id=p_actor and client_operation_id=p_client_operation;
  if found then
    if previous.profile_id<>p_profile or previous.action<>'profile_status' or previous.details->'request'<>request then
      raise exception 'operation_id_conflict';
    end if;
    return previous.details->'result' || jsonb_build_object('replayed',true);
  end if;
  select * into item from public.profiles where id=p_profile for update;
  if not found or p_expected_updated_at is null or item.updated_at<>p_expected_updated_at then raise exception 'profile_version_conflict'; end if;
  update public.profiles set disabled_at=case when p_enabled then null else coalesce(disabled_at,clock_timestamp()) end,
    updated_at=clock_timestamp() where id=p_profile returning * into item;
  result:=jsonb_build_object('profile',to_jsonb(item),'replayed',false);
  insert into private.admin_audit(actor_user_id,profile_id,action,client_operation_id,details)
    values(p_actor,p_profile,'profile_status',p_client_operation,jsonb_build_object('request',request,'result',result));
  return result;
end;
$$;

-- Server-uploaded managed photos have no Auth owner. Check the current profile
-- path and either ordinary self/contact visibility or a fresh assigned grant.
create function private.can_read_managed_avatar(target text) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select private.is_member()) and exists(
    select 1 from public.profiles p where p.profile_kind='managed' and p.avatar_path=target
      and (private.can_read_profile(p.id) or exists(
        select 1 from private.managed_profile_grants g join private.admin_roles r on r.user_id=g.user_id
        where g.user_id=(select auth.uid()) and g.profile_id=p.id and g.revoked_at is null
          and r.revoked_at is null and (g.can_manage or g.can_reply)
      ))
  );
$$;
create policy managed_avatar_read on storage.objects for select to authenticated
  using(bucket_id='avatars' and private.can_read_managed_avatar(name));
revoke all on function private.can_read_managed_avatar(text) from public,anon;
grant execute on function private.can_read_managed_avatar(text) to authenticated,service_role;
revoke all on function public.admin_prepare_create(uuid,uuid),public.admin_authorize_save(uuid,uuid,boolean,uuid),
  public.admin_save_profile(uuid,uuid,boolean,uuid,jsonb,timestamptz),
  public.admin_set_profile_enabled(uuid,uuid,boolean,uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.admin_prepare_create(uuid,uuid),public.admin_authorize_save(uuid,uuid,boolean,uuid),
  public.admin_save_profile(uuid,uuid,boolean,uuid,jsonb,timestamptz),
  public.admin_set_profile_enabled(uuid,uuid,boolean,uuid,timestamptz) to service_role;

-- Active network visibility changes atomically with disabling. Connections and
-- conversation membership/history remain intact so restore is reversible.
create or replace function private.can_read_profile(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member() and exists(select 1 from public.profiles p where p.id=target and p.disabled_at is null)
    and (target=(select auth.uid()) or exists(select 1 from public.connections
      where user_low=least(target,(select auth.uid())) and user_high=greatest(target,(select auth.uid()))));
$$;
create or replace function public.member_network(p_user uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'profile',(select to_jsonb(p) || jsonb_build_object('contact_count',
      (select count(*) from public.connections c join public.profiles peer
        on peer.id=case when c.user_low=p.id then c.user_high else c.user_low end
        where (c.user_low=p.id or c.user_high=p.id) and peer.disabled_at is null))
      from public.profiles p where p.id=p_user and exists(select 1 from private.memberships where user_id=p_user)),
    'contacts',coalesce((select jsonb_agg(to_jsonb(p) || jsonb_build_object('contact_count',
      (select count(*) from public.connections c join public.profiles peer
        on peer.id=case when c.user_low=p.id then c.user_high else c.user_low end
        where (c.user_low=p.id or c.user_high=p.id) and peer.disabled_at is null)))
      from public.profiles p join public.connections c on (c.user_low=p_user and c.user_high=p.id) or (c.user_high=p_user and c.user_low=p.id)
      where p.disabled_at is null and exists(select 1 from private.memberships where user_id=p_user)),'[]'::jsonb));
$$;

create function private.require_active_chat_profiles(p_conversation uuid) returns void
language plpgsql set search_path = '' as $$
declare item record;
begin
  -- All send paths acquire profile locks before the existing pair/thread locks.
  for item in select p.disabled_at from public.profiles p join public.conversations c
    on p.id=c.user_low or p.id=c.user_high where c.id=p_conversation order by p.id for share of p loop
    if item.disabled_at is not null then raise exception 'conversation_forbidden'; end if;
  end loop;
end;
$$;
revoke all on function private.require_active_chat_profiles(uuid) from public,anon,authenticated;
grant execute on function private.require_active_chat_profiles(uuid) to service_role;

create or replace function public.chat_send(p_user uuid,p_conversation uuid,p_client_message uuid,p_text text) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.messages; thread public.conversations; became_connected boolean:=false;
begin
  perform private.require_chat_member(p_user,p_conversation);
  perform private.require_active_chat_profiles(p_conversation);
  if p_conversation is null or p_client_message is null or p_text is null
    or length(btrim(p_text))<1 or octet_length(p_text)>65536 then raise exception 'invalid_message'; end if;
  select * into thread from public.conversations where id=p_conversation;
  -- All connection mutations lock the canonical pair before the conversation.
  perform pg_advisory_xact_lock(hashtextextended(thread.user_low::text || thread.user_high::text,10));
  select * into thread from public.conversations where id=p_conversation for update;
  select * into item from public.messages where conversation_id=p_conversation
    and actor_user_id=p_user and client_message_id=p_client_message;
  if found then
    if item.text<>p_text then raise exception 'message_id_conflict'; end if;
    return jsonb_build_object('message',to_jsonb(item),'replayed',true,'connected',false);
  end if;
  update public.conversations set last_message_seq=last_message_seq+1,updated_at=clock_timestamp()
    where id=p_conversation returning * into thread;
  insert into public.messages(conversation_id,seq,sender_profile_id,actor_user_id,client_message_id,text)
    values(p_conversation,thread.last_message_seq,p_user,p_user,p_client_message,p_text) returning * into item;
  if not exists(select 1 from public.connections where user_low=thread.user_low and user_high=thread.user_high)
    and exists(select 1 from public.messages where conversation_id=p_conversation and seq>thread.connection_start_seq and sender_profile_id=thread.user_low)
    and exists(select 1 from public.messages where conversation_id=p_conversation and seq>thread.connection_start_seq and sender_profile_id=thread.user_high) then
    insert into public.connections(user_low,user_high) values(thread.user_low,thread.user_high) on conflict do nothing;
    became_connected:=found;
  end if;
  -- The outbox intentionally contains no message text or provider credentials.
  -- Actual browser push delivery is a separate, unconfigured transport.
  insert into private.notification_jobs(message_id,conversation_id,recipient_user_id)
    values(item.id,p_conversation,case when p_user=thread.user_low then thread.user_high else thread.user_low end);
  return jsonb_build_object('message',to_jsonb(item),'replayed',false,'connected',became_connected);
end;
$$;

create function private.managed_profile_notify_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  for recipient in select distinct p.auth_user_id from public.connections c join public.profiles p
    on p.id=case when c.user_low=new.id then c.user_high else c.user_low end
    where (c.user_low=new.id or c.user_high=new.id) and p.auth_user_id is not null loop
    perform realtime.send(jsonb_build_object('network_changed',true),'changed','chat:user:' || recipient::text,true);
  end loop;
  return new;
end;
$$;
create trigger managed_profile_notify_status after update of disabled_at on public.profiles
  for each row when (old.disabled_at is distinct from new.disabled_at) execute function private.managed_profile_notify_status();
revoke all on function private.managed_profile_notify_status() from public,anon,authenticated;
grant execute on function private.managed_profile_notify_status() to service_role;
