-- The inbox channel belongs to the authenticated account. It carries only
-- invalidation hints, never message bodies, names, or bearer credentials.
create policy chat_private_receive on realtime.messages for select to authenticated
  using (
    (select private.is_member()) and extension='broadcast'
    and topic=(select realtime.topic())
    and (select realtime.topic())='chat:user:' || (select auth.uid())::text
  );

create function private.chat_notify_message() returns trigger
language plpgsql security definer set search_path = '' as $$
declare recipient uuid;
begin
  for recipient in select user_id from public.conversation_members where conversation_id=new.conversation_id loop
    perform realtime.send(jsonb_build_object('conversation_id',new.conversation_id,'seq',new.seq),
      'changed','chat:user:' || recipient::text,true);
  end loop;
  return new;
end;
$$;
create trigger chat_notify_message after insert on public.messages
  for each row execute function private.chat_notify_message();

create function private.chat_notify_read() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform realtime.send(jsonb_build_object('conversation_id',new.conversation_id,'read_seq',new.last_read_seq),
    'changed','chat:user:' || new.user_id::text,true);
  return new;
end;
$$;
create trigger chat_notify_read after update of last_read_seq on public.conversation_members
  for each row when (old.last_read_seq is distinct from new.last_read_seq) execute function private.chat_notify_read();

create function private.chat_notify_connection() returns trigger
language plpgsql security definer set search_path = '' as $$
declare low_id uuid; high_id uuid;
begin
  if tg_op='DELETE' then low_id:=old.user_low; high_id:=old.user_high;
  else low_id:=new.user_low; high_id:=new.user_high; end if;
  perform realtime.send(jsonb_build_object('network_changed',true),'changed','chat:user:' || low_id::text,true);
  perform realtime.send(jsonb_build_object('network_changed',true),'changed','chat:user:' || high_id::text,true);
  return null;
end;
$$;
create trigger chat_notify_connection after insert or delete on public.connections
  for each row execute function private.chat_notify_connection();
revoke all on function private.chat_notify_message(),private.chat_notify_read(),private.chat_notify_connection()
  from public,anon,authenticated;
grant execute on function private.chat_notify_message(),private.chat_notify_read(),private.chat_notify_connection()
  to service_role;
