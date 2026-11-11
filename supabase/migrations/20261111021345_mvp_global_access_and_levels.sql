alter table public.profiles add column deleted_at timestamptz;

-- Completed registration is credited once, independently of later reconnects.
create table private.invited_registrations (
  invitee_profile_id uuid primary key references public.profiles(id),
  inviter_profile_id uuid not null references public.profiles(id),
  registered_at timestamptz not null,
  check (invitee_profile_id<>inviter_profile_id)
);
create index invited_registrations_inviter_idx on private.invited_registrations(inviter_profile_id);
alter table private.invited_registrations enable row level security;
revoke all on private.invited_registrations from public,anon,authenticated;
grant all on private.invited_registrations to service_role;

-- Earlier versions finalized membership with the first redemption. Bootstrap
-- has no issuer, and later redemptions are reconnections rather than signups.
insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
select r.user_id,i.issuer_id,r.redeemed_at
from (
  select distinct on(user_id) user_id,invitation_id,redeemed_at
  from private.invite_redemptions order by user_id,redeemed_at,invitation_id
) r
join private.invitations i on i.id=r.invitation_id
join private.memberships m on m.user_id=r.user_id
where i.issuer_id is not null and i.issuer_id<>r.user_id
  and m.activated_at between i.created_at and r.redeemed_at;

create table private.first_contact_days (
  actor_profile_id uuid not null references public.profiles(id),
  day_utc date not null,
  peer_profile_id uuid not null references public.profiles(id),
  created_at timestamptz not null default clock_timestamp(),
  primary key(actor_profile_id,day_utc),
  check (actor_profile_id<>peer_profile_id)
);
alter table private.first_contact_days enable row level security;
revoke all on private.first_contact_days from public,anon,authenticated;
grant all on private.first_contact_days to service_role;

create function private.invited_registration_count(p_user uuid) returns bigint
language sql stable set search_path = '' as $$
  select count(*) from private.invited_registrations where inviter_profile_id=p_user;
$$;

create or replace function private.is_member() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(
    select 1 from private.memberships m join public.profiles p on p.id=m.user_id
    where m.user_id=(select auth.uid()) and p.auth_user_id=m.user_id
      and p.profile_kind='member' and p.disabled_at is null and p.deleted_at is null
  );
$$;

create or replace function private.can_read_profile(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member() and exists(
    select 1 from public.profiles p where p.id=target
      and p.disabled_at is null and p.deleted_at is null
      and (p.profile_kind='managed' or exists(select 1 from private.memberships m where m.user_id=p.id))
  );
$$;

create or replace function private.require_chat_member(p_user uuid,p_conversation uuid) returns void
language plpgsql set search_path = '' as $$
begin
  if p_user is null or not exists(
    select 1 from private.memberships m join public.profiles p on p.id=m.user_id
    where m.user_id=p_user and p.auth_user_id=p_user and p.profile_kind='member'
      and p.disabled_at is null and p.deleted_at is null
  ) then raise exception 'membership_required'; end if;
  if p_conversation is not null and not exists(
    select 1 from public.conversation_members where conversation_id=p_conversation and user_id=p_user
  ) then raise exception 'conversation_forbidden'; end if;
end;
$$;

create function private.require_member_session(p_user uuid,p_session uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not private.push_session_active(p_user,p_session) then raise exception 'session_revoked'; end if;
  perform private.require_chat_member(p_user,null);
end;
$$;

create function public.member_require_session(p_user uuid,p_session uuid) returns void
language sql stable set search_path = '' as $$
  select private.require_member_session(p_user,p_session);
$$;

create function public.member_capabilities(p_user uuid,p_session uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare registrations bigint; today date;
begin
  perform private.require_member_session(p_user,p_session);
  registrations:=private.invited_registration_count(p_user);
  today:=(clock_timestamp() at time zone 'UTC')::date;
  return jsonb_build_object(
    'invited_registrations',registrations,
    'can_message_anyone',registrations>=2,
    'can_publish_community',registrations>=10,
    'offering_limit',case when registrations>=10 then null else 5 end,
    'new_conversations_remaining',case when registrations>=2 then null
      when exists(select 1 from private.first_contact_days where actor_profile_id=p_user and day_utc=today) then 0 else 1 end,
    'quota_resets_at',(today+1)::timestamp at time zone 'UTC'
  );
end;
$$;

create function private.require_community_publisher(p_user uuid) returns void
language plpgsql stable set search_path = '' as $$
begin
  perform private.require_chat_member(p_user,null);
  if private.invited_registration_count(p_user)<10 then raise exception 'community_locked'; end if;
end;
$$;

create function private.claim_new_contact(p_actor uuid,p_peer uuid,p_conversation uuid) returns void
language plpgsql set search_path = '' as $$
declare today date;
begin
  -- The sending command holds the actor lock and the conversation pair lock.
  if private.invited_registration_count(p_actor)>=2
    or exists(select 1 from public.connections where user_low=least(p_actor,p_peer) and user_high=greatest(p_actor,p_peer))
    or exists(select 1 from public.messages where conversation_id=p_conversation) then return; end if;
  today:=(clock_timestamp() at time zone 'UTC')::date;
  insert into private.first_contact_days(actor_profile_id,day_utc,peer_profile_id)
    values(p_actor,today,p_peer) on conflict do nothing;
  if not found and not exists(
    select 1 from private.first_contact_days where actor_profile_id=p_actor and day_utc=today and peer_profile_id=p_peer
  ) then raise exception 'new_contact_limit_reached'; end if;
end;
$$;

-- A registered viewer can fetch only the current published avatar version.
-- The existing owner policy also permits private management of own uploads.
drop policy avatar_read on storage.objects;
create policy avatar_active_profile_read on storage.objects for select to authenticated
using(bucket_id='avatars' and exists(
  select 1 from public.profiles p where p.avatar_path=storage.objects.name and private.can_read_profile(p.id)
));

create or replace function private.valid_skills(items text[],required boolean) returns boolean
language sql immutable set search_path = '' as $$
  select items is not null and cardinality(items)>=(case when required then 1 else 0 end)
    and (required or cardinality(items)<=100)
    and not exists(select 1 from unnest(items) s where s is null or length(btrim(s))<1 or octet_length(s)>32768)
    and (select count(*)=count(distinct lower(regexp_replace(btrim(s),'\s+',' ','g'))) from unnest(items) s);
$$;

revoke all on function private.invited_registration_count(uuid),private.require_community_publisher(uuid),
  private.claim_new_contact(uuid,uuid,uuid),public.member_capabilities(uuid,uuid) from public,anon,authenticated;
grant execute on function private.invited_registration_count(uuid),private.require_community_publisher(uuid),
  private.claim_new_contact(uuid,uuid,uuid),public.member_capabilities(uuid,uuid) to service_role;


create or replace function private.save_profile(member_id uuid, draft jsonb) returns void
language plpgsql set search_path = '' as $$
declare offered text[]; searching text[]; avatar text; legacy_count integer;
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
  select cardinality(skills) into legacy_count from public.profiles where id=member_id for update;
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
declare item private.invitations; already_member boolean;
begin
  -- A per-user lock serializes first registration with different invitations.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text, 0));
  select * into item from private.invitations
    where (not p_manual and token_hash = p_hash) or (p_manual and code_hash = p_hash)
    for update;
  if not found then raise exception 'invalid_invitation'; end if;
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

create or replace function public.chat_open(p_user uuid,p_peer uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.conversations;
begin
  perform private.require_chat_member(p_user,null);
  if p_user=p_peer then raise exception 'self_conversation'; end if;
  perform 1 from public.profiles p where p.id=p_peer and p.disabled_at is null and p.deleted_at is null
    and (p.profile_kind='managed' or exists(select 1 from private.memberships where user_id=p_peer)) for share;
  if not found then raise exception 'conversation_forbidden'; end if;
  perform pg_advisory_xact_lock(hashtextextended(least(p_user,p_peer)::text || greatest(p_user,p_peer)::text,10));
  select * into item from public.conversations where user_low=least(p_user,p_peer) and user_high=greatest(p_user,p_peer);
  if not found then
    insert into public.conversations(user_low,user_high) values(least(p_user,p_peer),greatest(p_user,p_peer)) returning * into item;
    insert into public.conversation_members(conversation_id,user_id) values(item.id,p_user),(item.id,p_peer);
  end if;
  return to_jsonb(item);
end;
$$;

create or replace function private.chat_send_as(p_actor uuid,p_sender uuid,p_conversation uuid,p_client_message uuid,p_text text) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.messages; thread public.conversations; became_connected boolean:=false;
begin
  if p_sender=p_actor then perform private.require_chat_member(p_actor,p_conversation);
  else
    perform private.require_managed_profile(p_actor,p_sender,true);
    if not exists(select 1 from public.conversation_members where conversation_id=p_conversation and user_id=p_sender) then
      raise exception 'conversation_forbidden';
    end if;
  end if;
  if p_conversation is null or p_client_message is null or p_text is null
    or length(btrim(p_text))<1 or octet_length(p_text)>65536 then raise exception 'invalid_message'; end if;
  perform private.require_active_chat_profiles(p_conversation);
  select * into thread from public.conversations where id=p_conversation;
  if p_sender=p_actor then perform pg_advisory_xact_lock(hashtextextended(p_actor::text,86)); end if;
  perform pg_advisory_xact_lock(hashtextextended(thread.user_low::text || thread.user_high::text,10));
  select * into thread from public.conversations where id=p_conversation for update;
  select * into item from public.messages where conversation_id=p_conversation and actor_user_id=p_actor and client_message_id=p_client_message;
  if found then
    if item.text<>p_text or item.sender_profile_id<>p_sender then raise exception 'message_id_conflict'; end if;
    return jsonb_build_object('message',to_jsonb(item),'replayed',true,'connected',false);
  end if;
  if p_sender=p_actor then
    perform private.claim_new_contact(p_actor,case when thread.user_low=p_sender then thread.user_high else thread.user_low end,p_conversation);
  end if;
  update public.conversations set last_message_seq=last_message_seq+1,updated_at=clock_timestamp() where id=p_conversation returning * into thread;
  insert into public.messages(conversation_id,seq,sender_profile_id,actor_user_id,client_message_id,text)
    values(p_conversation,thread.last_message_seq,p_sender,p_actor,p_client_message,p_text) returning * into item;
  if not exists(select 1 from public.connections where user_low=thread.user_low and user_high=thread.user_high)
    and exists(select 1 from public.messages where conversation_id=p_conversation and seq>thread.connection_start_seq and sender_profile_id=thread.user_low)
    and exists(select 1 from public.messages where conversation_id=p_conversation and seq>thread.connection_start_seq and sender_profile_id=thread.user_high) then
    insert into public.connections(user_low,user_high) values(thread.user_low,thread.user_high) on conflict do nothing;
    became_connected:=found;
  end if;
  insert into private.notification_jobs(message_id,conversation_id,recipient_user_id)
    values(item.id,p_conversation,case when p_sender=thread.user_low then thread.user_high else thread.user_low end);
  return jsonb_build_object('message',to_jsonb(item),'replayed',false,'connected',became_connected);
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
        'peer',jsonb_build_object('id',p.id,'name',p.name,'occupation',p.occupation,'avatar_path',p.avatar_path),
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
      'peer',jsonb_build_object('id',p.id,'name',p.name,'occupation',p.occupation,'avatar_path',null),
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

create or replace function private.can_read_conversation(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member() and exists(
    select 1 from public.conversation_members m join public.conversations c on c.id=m.conversation_id
    where m.conversation_id=target and m.user_id=(select auth.uid()) and c.last_message_seq>0
  );
$$;

create or replace function private.chat_notify_read() returns trigger
language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  if new.last_read_seq is not distinct from old.last_read_seq then return new; end if;
  select auth_user_id into recipient from public.profiles where id=new.user_id;
  if recipient is not null then
    perform realtime.send(jsonb_build_object('conversation_id',new.conversation_id,'read_seq',new.last_read_seq),'changed','chat:user:' || recipient::text,true);
  else perform private.notify_managed_operators(new.user_id); end if;
  return new;
end;
$$;

create or replace function private.require_active_chat_profiles(p_conversation uuid) returns void
language plpgsql set search_path = '' as $$
declare item record;
begin
  -- All send paths acquire profile locks before the existing pair/thread locks.
  for item in select p.disabled_at,p.deleted_at from public.profiles p join public.conversations c
    on p.id=c.user_low or p.id=c.user_high where c.id=p_conversation order by p.id for share of p loop
    if item.disabled_at is not null or item.deleted_at is not null then raise exception 'conversation_forbidden'; end if;
  end loop;
end;
$$;

create function public.member_profile(p_user uuid,p_session uuid,p_profile uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare item jsonb;
begin
  perform private.require_member_session(p_user,p_session);
  select to_jsonb(p)||jsonb_build_object('contact_count',
    (select count(*) from public.connections c join public.profiles peer
      on peer.id=case when c.user_low=p.id then c.user_high else c.user_low end
      where (c.user_low=p.id or c.user_high=p.id) and peer.disabled_at is null and peer.deleted_at is null))
    into item from public.profiles p where p.id=p_profile and p.disabled_at is null and p.deleted_at is null
      and (p.profile_kind='managed' or exists(select 1 from private.memberships where user_id=p.id));
  if item is null then raise exception 'profile_unavailable'; end if;
  return jsonb_build_object('profile',item);
end;
$$;
revoke all on function private.require_member_session(uuid,uuid),public.member_require_session(uuid,uuid),
  public.member_profile(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.require_member_session(uuid,uuid),public.member_require_session(uuid,uuid),
  public.member_profile(uuid,uuid,uuid) to service_role;
