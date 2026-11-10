-- Notification clicks authorize the current binding/session and chat access.
-- The event age bounds dispatch attempts only, independently of click access.
create or replace function private.push_route(p_user uuid,p_session uuid,p_job uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare job private.notification_jobs; recipient public.profiles;
begin
  if not private.push_session_active(p_user,p_session) or not exists(
    select 1 from private.memberships m join public.profiles p on p.id=m.user_id
      where m.user_id=p_user and p.auth_user_id=p_user and p.disabled_at is null) then return null; end if;
  select * into job from private.notification_jobs where id=p_job;
  if not found then return null; end if;
  if not exists(select 1 from public.conversation_members where conversation_id=job.conversation_id and user_id=job.recipient_user_id)
    or exists(select 1 from public.profiles p join public.conversation_members m on m.user_id=p.id
      where m.conversation_id=job.conversation_id and p.disabled_at is not null) then return null; end if;
  select * into recipient from public.profiles where id=job.recipient_user_id;
  if recipient.profile_kind='member' and recipient.auth_user_id=p_user then
    return jsonb_build_object('kind','chat','conversation_id',job.conversation_id);
  end if;
  if recipient.profile_kind='managed' and exists(select 1 from private.admin_roles r join private.managed_profile_grants g on g.user_id=r.user_id
    where r.user_id=p_user and r.revoked_at is null and g.profile_id=recipient.id and g.can_reply and g.revoked_at is null) then
    return jsonb_build_object('kind','operator','conversation_id',job.conversation_id,'managed_profile_id',recipient.id);
  end if;
  return null;
end;
$$;

create or replace function public.push_claim(p_limit integer default 10) returns jsonb
language plpgsql set search_path = '' set statement_timeout = '8s' as $$
declare job private.notification_jobs; item private.push_subscriptions; delivery private.push_deliveries;
  result jsonb:='[]'::jsonb; fence uuid;
begin
  if p_limit is null or p_limit<1 or p_limit>20 then raise exception 'invalid_request'; end if;
  for job in select * from private.notification_jobs where push_expanded_at is null order by created_at,id for update skip locked limit 20 loop
    for item in select s.* from private.push_subscriptions s
      join public.profiles p on p.id=job.recipient_user_id
      where s.disabled_at is null and s.bound_at<=job.created_at and (s.expires_at is null or s.expires_at>clock_timestamp())
        and ((p.profile_kind='member' and s.user_id=p.auth_user_id) or (p.profile_kind='managed' and exists(
          select 1 from private.managed_profile_grants g where g.user_id=s.user_id and g.profile_id=p.id and g.can_reply and g.revoked_at is null))) loop
      if job.created_at+interval '24 hours'>clock_timestamp()+interval '30 seconds'
        and private.push_route(item.user_id,item.session_id,job.id) is not null then
        insert into private.push_deliveries(job_id,binding_id) values(job.id,item.binding_id) on conflict do nothing;
      end if;
    end loop;
    update private.notification_jobs set push_expanded_at=clock_timestamp() where id=job.id;
  end loop;
  for delivery in select * from private.push_deliveries
    where ((status='pending' and next_attempt_at<=clock_timestamp()) or (status='leased' and lease_until<=clock_timestamp()))
    order by next_attempt_at,id for update skip locked limit p_limit loop
    select * into item from private.push_subscriptions where binding_id=delivery.binding_id;
    if delivery.attempts>=5 then
      update private.push_deliveries set status='failed',lease_token=null,lease_until=null where id=delivery.id;
    elsif item.disabled_at is not null or (item.expires_at is not null and item.expires_at<=clock_timestamp())
      or exists(select 1 from private.notification_jobs where id=delivery.job_id
        and created_at+interval '24 hours'<=clock_timestamp()+interval '30 seconds')
      or private.push_route(item.user_id,item.session_id,delivery.job_id) is null then
      update private.push_deliveries set status='cancelled',lease_token=null,lease_until=null where id=delivery.id;
    else
      fence:=gen_random_uuid();
      update private.push_deliveries set status='leased',attempts=attempts+1,lease_token=fence,lease_until=clock_timestamp()+interval '60 seconds'
        where id=delivery.id;
      result:=result||jsonb_build_array(jsonb_build_object('delivery_id',delivery.id,'lease_token',fence));
    end if;
  end loop;
  return result;
end;
$$;
