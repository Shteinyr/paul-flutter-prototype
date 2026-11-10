alter table public.conversations add column connection_start_seq bigint not null default 0
  check (connection_start_seq between 0 and last_message_seq);

create table private.notification_jobs (
  id uuid primary key default gen_random_uuid(),
  message_id uuid not null unique references public.messages(id),
  conversation_id uuid not null references public.conversations(id),
  recipient_user_id uuid not null references public.profiles(id),
  kind text not null default 'message_created' check (kind='message_created'),
  created_at timestamptz not null default clock_timestamp()
);
create index notification_jobs_recipient_idx on private.notification_jobs(recipient_user_id,created_at);
create index notification_jobs_conversation_idx on private.notification_jobs(conversation_id);
alter table private.notification_jobs enable row level security;
revoke all on private.notification_jobs from public,anon,authenticated;
grant all on private.notification_jobs to service_role;

-- A retry of an old removal must not remove a connection recreated since then.
create table private.connection_removals (
  actor_user_id uuid not null references auth.users(id),
  client_operation_id uuid not null,
  user_low uuid not null references public.profiles(id),
  user_high uuid not null references public.profiles(id),
  result jsonb not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key(actor_user_id,client_operation_id),
  check (user_low<user_high)
);
create index connection_removals_low_idx on private.connection_removals(user_low);
create index connection_removals_high_idx on private.connection_removals(user_high);
alter table private.connection_removals enable row level security;
revoke all on private.connection_removals from public,anon,authenticated;
grant all on private.connection_removals to service_role;

create or replace function public.chat_send(p_user uuid,p_conversation uuid,p_client_message uuid,p_text text) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.messages; thread public.conversations; became_connected boolean:=false;
begin
  perform private.require_chat_member(p_user,p_conversation);
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

create function public.chat_disconnect(p_user uuid,p_peer uuid,p_client_operation uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare low_id uuid; high_id uuid; previous private.connection_removals; removed boolean; result jsonb;
begin
  perform private.require_chat_member(p_user,null);
  if p_peer is null or p_client_operation is null then raise exception 'invalid_request'; end if;
  if p_peer=p_user then raise exception 'self_conversation'; end if;
  low_id:=least(p_user,p_peer); high_id:=greatest(p_user,p_peer);
  -- An actor lock also serializes reuse of an operation ID for different peers.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text || p_client_operation::text,11));
  select * into previous from private.connection_removals where actor_user_id=p_user and client_operation_id=p_client_operation;
  if found then
    if previous.user_low<>low_id or previous.user_high<>high_id then raise exception 'operation_id_conflict'; end if;
    return previous.result || jsonb_build_object('replayed',true);
  end if;
  perform pg_advisory_xact_lock(hashtextextended(low_id::text || high_id::text,10));
  if not exists(select 1 from public.connections where user_low=low_id and user_high=high_id)
    and not exists(select 1 from public.conversations where user_low=low_id and user_high=high_id) then
    raise exception 'conversation_forbidden';
  end if;
  delete from public.connections where user_low=low_id and user_high=high_id;
  removed:=found;
  if removed then
    update public.conversations set connection_start_seq=last_message_seq where user_low=low_id and user_high=high_id;
  end if;
  result:=jsonb_build_object('removed',removed,'replayed',false);
  insert into private.connection_removals(actor_user_id,client_operation_id,user_low,user_high,result)
    values(p_user,p_client_operation,low_id,high_id,result);
  return result;
end;
$$;
revoke all on function public.chat_disconnect(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.chat_disconnect(uuid,uuid,uuid) to service_role;

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
