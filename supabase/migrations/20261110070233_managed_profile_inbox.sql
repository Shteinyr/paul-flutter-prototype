-- Read access to assigned managed history includes disabled profiles. Sending
-- uses the stricter require_managed_profile(...,true) active-profile check.
create function private.require_operator_profile(p_actor uuid,p_profile uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform private.require_admin(p_actor);
  perform 1 from private.managed_profile_grants where user_id=p_actor and profile_id=p_profile
    and can_reply and revoked_at is null for share;
  if not found then raise exception 'managed_profile_forbidden'; end if;
  perform 1 from public.profiles where id=p_profile and profile_kind='managed' for share;
  if not found then raise exception 'managed_profile_forbidden'; end if;
end;
$$;
create function private.require_operator_conversation(p_actor uuid,p_profile uuid,p_conversation uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform private.require_operator_profile(p_actor,p_profile);
  if p_conversation is null or not exists(select 1 from public.conversation_members
    where conversation_id=p_conversation and user_id=p_profile) then raise exception 'conversation_forbidden'; end if;
end;
$$;

create function public.operator_inbox(p_actor uuid,p_profile uuid) returns jsonb
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
    where m.user_id=p_profile
  ) rows;
  return jsonb_build_object('conversations',result,'profile_disabled',(select disabled_at is not null from public.profiles where id=p_profile));
end;
$$;

create function public.operator_history(p_actor uuid,p_profile uuid,p_conversation uuid,p_before bigint default null,
  p_after bigint default null,p_limit integer default 50) returns jsonb
language plpgsql set search_path = '' as $$
declare result jsonb;
begin
  perform private.require_operator_conversation(p_actor,p_profile,p_conversation);
  if p_limit is null or p_limit not between 1 and 100 or (p_before is not null and p_after is not null)
    or p_before<1 or p_after<0 then raise exception 'invalid_request'; end if;
  select coalesce(jsonb_agg(to_jsonb(rows) order by seq),'[]'::jsonb) into result from (
    select * from public.messages where conversation_id=p_conversation
      and (p_before is null or seq<p_before) and (p_after is null or seq>p_after)
    order by case when p_after is not null then seq end asc,seq desc limit p_limit
  ) rows;
  return jsonb_build_object('messages',result,'last_message_seq',(select last_message_seq from public.conversations where id=p_conversation));
end;
$$;
create function public.operator_read(p_actor uuid,p_profile uuid,p_conversation uuid,p_through bigint) returns jsonb
language plpgsql set search_path = '' as $$
declare upto bigint;
begin
  perform private.require_operator_conversation(p_actor,p_profile,p_conversation);
  if p_through is null or p_through<0 then raise exception 'invalid_request'; end if;
  perform 1 from public.conversations where id=p_conversation for update;
  if p_through>(select last_message_seq from public.conversations where id=p_conversation) then raise exception 'invalid_request'; end if;
  update public.conversation_members set last_read_seq=greatest(last_read_seq,p_through)
    where conversation_id=p_conversation and user_id=p_profile returning last_read_seq into upto;
  return jsonb_build_object('last_read_seq',upto);
end;
$$;

-- Both normal and managed sends share the accepted P10 transaction algorithm.
-- The author check remains in the database as well as the Edge wrapper.
create function private.check_message_author() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.sender_profile_id=new.actor_user_id then
    perform private.require_chat_member(new.actor_user_id,new.conversation_id);
  else
    perform private.require_managed_profile(new.actor_user_id,new.sender_profile_id,true);
  end if;
  return new;
end;
$$;
alter table public.messages drop constraint messages_check;
create trigger check_message_author before insert on public.messages
  for each row execute function private.check_message_author();

create function private.chat_send_as(p_actor uuid,p_sender uuid,p_conversation uuid,p_client_message uuid,p_text text) returns jsonb
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
  perform pg_advisory_xact_lock(hashtextextended(thread.user_low::text || thread.user_high::text,10));
  select * into thread from public.conversations where id=p_conversation for update;
  select * into item from public.messages where conversation_id=p_conversation and actor_user_id=p_actor and client_message_id=p_client_message;
  if found then
    if item.text<>p_text or item.sender_profile_id<>p_sender then raise exception 'message_id_conflict'; end if;
    return jsonb_build_object('message',to_jsonb(item),'replayed',true,'connected',false);
  end if;
  update public.conversations set last_message_seq=last_message_seq+1,updated_at=clock_timestamp() where id=p_conversation returning * into thread;
  insert into public.messages(conversation_id,seq,sender_profile_id,actor_user_id,client_message_id,text)
    values(p_conversation,thread.last_message_seq,p_sender,p_actor,p_client_message,p_text) returning * into item;
  -- Until managed-profile audience is agreed, it cannot create connections.
  if (select bool_and(profile_kind='member') from public.profiles where id in (thread.user_low,thread.user_high))
    and not exists(select 1 from public.connections where user_low=thread.user_low and user_high=thread.user_high)
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
create or replace function public.chat_send(p_user uuid,p_conversation uuid,p_client_message uuid,p_text text) returns jsonb
language sql set search_path = '' as $$
  select private.chat_send_as(p_user,p_user,p_conversation,p_client_message,p_text);
$$;

create function public.operator_send(p_actor uuid,p_profile uuid,p_conversation uuid,p_client_message uuid,p_text text) returns jsonb
language plpgsql set search_path = '' as $$
declare previous private.admin_audit; result jsonb;
begin
  perform private.require_managed_profile(p_actor,p_profile,true);
  if p_client_message is null then raise exception 'invalid_message'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_actor::text || p_client_message::text,43));
  select * into previous from private.admin_audit where actor_user_id=p_actor and client_operation_id=p_client_message;
  if found and (previous.action<>'reply_as' or previous.profile_id<>p_profile
    or previous.details->>'conversation_id' is distinct from p_conversation::text) then raise exception 'operation_id_conflict'; end if;
  result:=private.chat_send_as(p_actor,p_profile,p_conversation,p_client_message,p_text);
  if previous.id is null then
    insert into private.admin_audit(actor_user_id,profile_id,action,client_operation_id,details)
      values(p_actor,p_profile,'reply_as',p_client_message,jsonb_build_object('conversation_id',p_conversation,'message_id',result->'message'->>'id'));
  end if;
  return result;
end;
$$;

create or replace function public.chat_open(p_user uuid,p_peer uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.conversations;
begin
  perform private.require_chat_member(p_user,null);
  if p_user=p_peer then raise exception 'self_conversation'; end if;
  perform 1 from public.profiles p where p.id=p_peer and p.disabled_at is null
    and (p.profile_kind='managed' or exists(select 1 from private.memberships where user_id=p_peer)) for share;
  if not found then raise exception 'conversation_forbidden'; end if;
  perform pg_advisory_xact_lock(hashtextextended(least(p_user,p_peer)::text || greatest(p_user,p_peer)::text,10));
  select * into item from public.conversations where user_low=least(p_user,p_peer) and user_high=greatest(p_user,p_peer);
  if not found then
    if not exists(select 1 from public.connections where user_low=least(p_user,p_peer) and user_high=greatest(p_user,p_peer)) then
      raise exception 'conversation_forbidden';
    end if;
    insert into public.conversations(user_low,user_high) values(least(p_user,p_peer),greatest(p_user,p_peer)) returning * into item;
    insert into public.conversation_members(conversation_id,user_id) values(item.id,p_user),(item.id,p_peer);
  end if;
  return to_jsonb(item);
end;
$$;

-- Metadata-only operator hints use a separate private topic, keeping the normal
-- account subscription alive while an operator opens an assigned inbox.
create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member() and exists(select 1 from private.admin_roles where user_id=(select auth.uid()) and revoked_at is null);
$$;
create policy admin_private_receive on realtime.messages for select to authenticated
  using((select private.is_admin()) and extension='broadcast' and topic=(select realtime.topic())
    and (select realtime.topic())='admin:user:' || (select auth.uid())::text);
create function private.notify_managed_operators(p_profile uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  for recipient in select g.user_id from private.managed_profile_grants g
    join private.admin_roles r on r.user_id=g.user_id join private.memberships m on m.user_id=g.user_id
    where g.profile_id=p_profile and g.can_reply and g.revoked_at is null and r.revoked_at is null loop
    perform realtime.send(jsonb_build_object('changed',true),'changed','admin:user:' || recipient::text,true);
  end loop;
end;
$$;
create or replace function private.chat_notify_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare participant record;
begin
  for participant in select p.id,p.auth_user_id from public.conversation_members m join public.profiles p on p.id=m.user_id where m.conversation_id=new.conversation_id loop
    if participant.auth_user_id is not null then
      perform realtime.send(jsonb_build_object('conversation_id',new.conversation_id,'seq',new.seq),'changed','chat:user:' || participant.auth_user_id::text,true);
    else perform private.notify_managed_operators(participant.id); end if;
  end loop;
  return new;
end;
$$;
create or replace function private.chat_notify_read() returns trigger
language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  select auth_user_id into recipient from public.profiles where id=new.user_id;
  if recipient is not null then
    perform realtime.send(jsonb_build_object('conversation_id',new.conversation_id,'read_seq',new.last_read_seq),'changed','chat:user:' || recipient::text,true);
  else perform private.notify_managed_operators(new.user_id); end if;
  return new;
end;
$$;
create function private.admin_access_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  if tg_op='DELETE' then recipient:=old.user_id; else recipient:=new.user_id; end if;
  perform realtime.send(jsonb_build_object('access_changed',true),'changed','admin:user:' || recipient::text,true);
  return null;
end;
$$;
create trigger admin_role_notify after insert or update or delete on private.admin_roles for each row execute function private.admin_access_notify();
create trigger admin_grant_notify after insert or update or delete on private.managed_profile_grants for each row execute function private.admin_access_notify();

revoke all on function private.is_admin() from public,anon;
grant execute on function private.is_admin() to authenticated,service_role;
revoke all on function private.require_operator_profile(uuid,uuid),private.require_operator_conversation(uuid,uuid,uuid),
  private.check_message_author(),private.chat_send_as(uuid,uuid,uuid,uuid,text),
  private.notify_managed_operators(uuid),private.admin_access_notify(),
  public.operator_inbox(uuid,uuid),public.operator_history(uuid,uuid,uuid,bigint,bigint,integer),
  public.operator_read(uuid,uuid,uuid,bigint),public.operator_send(uuid,uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function private.require_operator_profile(uuid,uuid),private.require_operator_conversation(uuid,uuid,uuid),
  private.check_message_author(),private.chat_send_as(uuid,uuid,uuid,uuid,text),
  private.notify_managed_operators(uuid),private.admin_access_notify(),
  public.operator_inbox(uuid,uuid),public.operator_history(uuid,uuid,uuid,bigint,bigint,integer),
  public.operator_read(uuid,uuid,uuid,bigint),public.operator_send(uuid,uuid,uuid,uuid,text) to service_role;

create function private.managed_operator_status_notify() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.notify_managed_operators(new.id);
  return new;
end;
$$;
create trigger managed_operator_status_notify after update of disabled_at on public.profiles
  for each row when(old.disabled_at is distinct from new.disabled_at) execute function private.managed_operator_status_notify();
revoke all on function private.managed_operator_status_notify() from public,anon,authenticated;
grant execute on function private.managed_operator_status_notify() to service_role;
