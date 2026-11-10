create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  user_low uuid not null references public.profiles(id),
  user_high uuid not null references public.profiles(id),
  created_at timestamptz not null default clock_timestamp(),
  last_message_seq bigint not null default 0 check (last_message_seq >= 0),
  updated_at timestamptz not null default clock_timestamp(),
  unique(user_low, user_high),
  check (user_low < user_high)
);
create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  last_read_seq bigint not null default 0 check (last_read_seq >= 0),
  primary key(conversation_id, user_id)
);
create index conversation_members_user_idx on public.conversation_members(user_id, conversation_id);
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  seq bigint not null check (seq > 0),
  sender_profile_id uuid not null references public.profiles(id),
  actor_user_id uuid not null references auth.users(id),
  client_message_id uuid not null,
  text text not null check (length(btrim(text)) > 0 and octet_length(text) <= 65536),
  created_at timestamptz not null default clock_timestamp(),
  unique(conversation_id, seq),
  unique(conversation_id, actor_user_id, client_message_id),
  check (sender_profile_id = actor_user_id),
  foreign key(conversation_id, sender_profile_id)
    references public.conversation_members(conversation_id, user_id)
);
create index messages_sender_idx on public.messages(sender_profile_id);
create index messages_actor_idx on public.messages(actor_user_id);
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;

-- The policy helper avoids recursive membership policies. Its only identity is
-- auth.uid(), never a browser-supplied user ID or editable user metadata.
create function private.can_read_conversation(target uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select (select private.is_member()) and exists (
    select 1 from public.conversation_members
    where conversation_id = target and user_id = (select auth.uid())
  );
$$;
revoke all on function private.can_read_conversation(uuid) from public, anon;
grant execute on function private.can_read_conversation(uuid) to authenticated, service_role;
create policy conversations_read on public.conversations for select to authenticated
  using (private.can_read_conversation(id));
create policy conversation_members_read on public.conversation_members for select to authenticated
  using (private.can_read_conversation(conversation_id));
create policy messages_read on public.messages for select to authenticated
  using (private.can_read_conversation(conversation_id));
revoke all on public.conversations, public.conversation_members, public.messages from public, anon, authenticated;
grant select on public.conversations, public.conversation_members, public.messages to authenticated;
grant all on public.conversations, public.conversation_members, public.messages to service_role;

create function private.require_chat_member(p_user uuid, p_conversation uuid) returns void
language plpgsql set search_path = '' as $$
begin
  if p_user is null or not exists(select 1 from private.memberships where user_id=p_user) then
    raise exception 'membership_required';
  end if;
  if p_conversation is not null and not exists (
    select 1 from public.conversation_members where conversation_id=p_conversation and user_id=p_user
  ) then raise exception 'conversation_forbidden'; end if;
end;
$$;
revoke all on function private.require_chat_member(uuid, uuid) from public, anon, authenticated;
grant execute on function private.require_chat_member(uuid, uuid) to service_role;

-- Edge verifies the bearer with Auth before calling these service-only RPCs.
-- Browser roles can SELECT under RLS but cannot forge p_user or mutate history.
create function public.chat_open(p_user uuid, p_peer uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.conversations;
begin
  perform private.require_chat_member(p_user, null);
  if p_user=p_peer then raise exception 'self_conversation'; end if;
  if p_peer is null then raise exception 'conversation_forbidden'; end if;
  perform pg_advisory_xact_lock(hashtextextended(least(p_user,p_peer)::text || greatest(p_user,p_peer)::text, 10));
  select * into item from public.conversations where user_low=least(p_user,p_peer) and user_high=greatest(p_user,p_peer);
  if not found then
    if not exists(select 1 from public.connections where user_low=least(p_user,p_peer) and user_high=greatest(p_user,p_peer))
      or not exists(select 1 from private.memberships where user_id=p_peer) then
      raise exception 'conversation_forbidden';
    end if;
    insert into public.conversations(user_low,user_high) values(least(p_user,p_peer),greatest(p_user,p_peer)) returning * into item;
    insert into public.conversation_members(conversation_id,user_id) values(item.id,p_user),(item.id,p_peer);
  end if;
  return to_jsonb(item);
end;
$$;

create function public.chat_list(p_user uuid) returns jsonb
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
    where m.user_id=p_user
  ) rows;
  return jsonb_build_object('conversations',result);
end;
$$;

create function public.chat_history(p_user uuid, p_conversation uuid, p_before bigint default null,
  p_after bigint default null, p_limit integer default 50) returns jsonb
language plpgsql set search_path = '' as $$
declare result jsonb;
begin
  perform private.require_chat_member(p_user,p_conversation);
  if p_conversation is null or p_limit is null or p_limit not between 1 and 100
    or (p_before is not null and p_after is not null) or p_before<1 or p_after<0 then
    raise exception 'invalid_request';
  end if;
  select coalesce(jsonb_agg(to_jsonb(rows) order by seq),'[]'::jsonb) into result from (
    select * from public.messages where conversation_id=p_conversation
      and (p_before is null or seq<p_before) and (p_after is null or seq>p_after)
    order by case when p_after is not null then seq end asc, seq desc limit p_limit
  ) rows;
  return jsonb_build_object('messages',result,'last_message_seq',
    (select last_message_seq from public.conversations where id=p_conversation));
end;
$$;

create function public.chat_send(p_user uuid, p_conversation uuid, p_client_message uuid, p_text text) returns jsonb
language plpgsql set search_path = '' as $$
declare item public.messages; next_seq bigint;
begin
  perform private.require_chat_member(p_user,p_conversation);
  if p_conversation is null or p_client_message is null or p_text is null
    or length(btrim(p_text))<1 or octet_length(p_text)>65536 then raise exception 'invalid_message'; end if;
  -- Assign sequence while holding the conversation row. A later committed
  -- message cannot jump ahead of an uncommitted message and be lost by catch-up.
  perform 1 from public.conversations where id=p_conversation for update;
  select * into item from public.messages where conversation_id=p_conversation
    and actor_user_id=p_user and client_message_id=p_client_message;
  if found then
    if item.text<>p_text then raise exception 'message_id_conflict'; end if;
    return jsonb_build_object('message',to_jsonb(item),'replayed',true,'connected',false);
  end if;
  update public.conversations set last_message_seq=last_message_seq+1,updated_at=clock_timestamp()
    where id=p_conversation returning last_message_seq into next_seq;
  insert into public.messages(conversation_id,seq,sender_profile_id,actor_user_id,client_message_id,text)
    values(p_conversation,next_seq,p_user,p_user,p_client_message,p_text) returning * into item;
  return jsonb_build_object('message',to_jsonb(item),'replayed',false,'connected',false);
end;
$$;

create function public.chat_read(p_user uuid, p_conversation uuid, p_through bigint) returns jsonb
language plpgsql set search_path = '' as $$
declare upto bigint;
begin
  perform private.require_chat_member(p_user,p_conversation);
  if p_conversation is null or p_through is null or p_through<0 then raise exception 'invalid_request'; end if;
  -- Serialize with sends. A forged future read cursor cannot hide later unread.
  perform 1 from public.conversations where id=p_conversation for update;
  if p_through>(select last_message_seq from public.conversations where id=p_conversation) then
    raise exception 'invalid_request';
  end if;
  update public.conversation_members set last_read_seq=greatest(last_read_seq,p_through)
    where conversation_id=p_conversation and user_id=p_user returning last_read_seq into upto;
  return jsonb_build_object('last_read_seq',upto);
end;
$$;
revoke all on function public.chat_open(uuid,uuid),public.chat_list(uuid),
  public.chat_history(uuid,uuid,bigint,bigint,integer),public.chat_send(uuid,uuid,uuid,text),
  public.chat_read(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.chat_open(uuid,uuid),public.chat_list(uuid),
  public.chat_history(uuid,uuid,bigint,bigint,integer),public.chat_send(uuid,uuid,uuid,text),
  public.chat_read(uuid,uuid,bigint) to service_role;
