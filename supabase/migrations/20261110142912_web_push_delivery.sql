-- Browser push capabilities stay in the private schema. A binding identifies
-- one account/session generation on one browser endpoint, never a managed user.
create table private.push_subscriptions (
  binding_id uuid primary key,
  user_id uuid not null references auth.users(id),
  session_id uuid not null,
  endpoint text not null check (octet_length(endpoint) between 20 and 2048),
  endpoint_hash text not null,
  p256dh text not null check (length(p256dh)=87),
  auth text not null check (length(auth)=22),
  expires_at timestamptz,
  bound_at timestamptz not null default clock_timestamp(),
  disabled_at timestamptz
);
create unique index push_endpoint_active_idx on private.push_subscriptions(endpoint_hash) where disabled_at is null;
create index push_subscriptions_user_idx on private.push_subscriptions(user_id,session_id) where disabled_at is null;

alter table private.notification_jobs add column push_expanded_at timestamptz;
-- There are no browser bindings before this feature is installed. Preserve the
-- existing outbox and explicitly prevent its history becoming fresh push work.
update private.notification_jobs set push_expanded_at=clock_timestamp();
create index notification_jobs_push_pending_idx on private.notification_jobs(created_at,id) where push_expanded_at is null;

create table private.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references private.notification_jobs(id),
  binding_id uuid not null references private.push_subscriptions(binding_id),
  status text not null default 'pending' check (status in ('pending','leased','sent','cancelled','failed')),
  attempts integer not null default 0 check (attempts between 0 and 5),
  next_attempt_at timestamptz not null default clock_timestamp(),
  lease_token uuid,
  lease_until timestamptz,
  sent_at timestamptz,
  last_code integer check (last_code between 0 and 599),
  unique(job_id,binding_id)
);
create index push_deliveries_ready_idx on private.push_deliveries(next_attempt_at,id) where status in ('pending','leased');
alter table private.push_subscriptions enable row level security;
alter table private.push_deliveries enable row level security;
revoke all on private.push_subscriptions,private.push_deliveries from public,anon,authenticated;
grant all on private.push_subscriptions,private.push_deliveries to service_role;

-- Auth does not grant service_role broad SELECT on its session table. This
-- deliberately narrow owner-executed predicate exposes only a boolean to the
-- service-only push RPCs. No Auth contents are returned to browser roles.
create function private.push_session_active(p_user uuid,p_session uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists(select 1 from auth.sessions where id=p_session and user_id=p_user
    and (not_after is null or not_after>clock_timestamp()));
$$;
revoke all on function private.push_session_active(uuid,uuid) from public,anon,authenticated;
grant execute on function private.push_session_active(uuid,uuid) to service_role;

create function private.require_push_member(p_user uuid,p_session uuid) returns void
language plpgsql set search_path = '' as $$
begin
  if not private.push_session_active(p_user,p_session) then raise exception 'session_revoked'; end if;
  if not exists(select 1 from private.memberships m join public.profiles p on p.id=m.user_id
    where m.user_id=p_user and p.auth_user_id=p_user and p.profile_kind='member' and p.disabled_at is null) then
    raise exception 'membership_required';
  end if;
end;
$$;

create function public.push_subscribe(p_user uuid,p_session uuid,p_binding uuid,p_endpoint text,p_p256dh text,p_auth text,p_expires timestamptz default null)
returns jsonb language plpgsql set search_path = '' as $$
declare item private.push_subscriptions; endpoint_key text;
begin
  perform private.require_push_member(p_user,p_session);
  if p_binding is null or p_endpoint is null or octet_length(p_endpoint)>2048
    or p_endpoint !~ '^https://(fcm[.]googleapis[.]com/(fcm/send|wp)/|updates[.]push[.]services[.]mozilla[.]com/wpush/|web[.]push[.]apple[.]com/)'
    or p_endpoint ~ '[[:space:]?#]' or p_p256dh !~ '^[A-Za-z0-9_-]{87}$' or p_auth !~ '^[A-Za-z0-9_-]{22}$'
    or p_p256dh is null or p_auth is null or (p_expires is not null and p_expires<=clock_timestamp()) then
    raise exception 'invalid_request';
  end if;
  endpoint_key:=encode(sha256(convert_to(p_endpoint,'UTF8')),'hex');
  -- A user lock makes the live-device cap real across different endpoints.
  -- Expired/revoked sessions do not consume that cap, without deleting history.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text,79));
  perform pg_advisory_xact_lock(hashtextextended(endpoint_key,78));
  select * into item from private.push_subscriptions where binding_id=p_binding for update;
  if found then
    if item.user_id<>p_user or item.session_id<>p_session or item.endpoint<>p_endpoint
      or item.p256dh<>p_p256dh or item.auth<>p_auth or item.disabled_at is not null
      or (item.expires_at is not null and item.expires_at<=clock_timestamp()) then
      raise exception 'binding_conflict';
    end if;
    return jsonb_build_object('binding_id',item.binding_id,'recipient_user_id',p_user,'enabled',true);
  end if;
  select * into item from private.push_subscriptions where endpoint_hash=endpoint_key and disabled_at is null for update;
  if found then
    if item.user_id=p_user and item.session_id=p_session and item.p256dh=p_p256dh and item.auth=p_auth
      and (item.expires_at is null or item.expires_at>clock_timestamp()) then
      -- Parallel tabs share this canonical generation and its original cutoff.
      return jsonb_build_object('binding_id',item.binding_id,'recipient_user_id',p_user,'enabled',true);
    end if;
    if private.push_session_active(item.user_id,item.session_id)
      and (item.expires_at is null or item.expires_at>clock_timestamp()) then raise exception 'binding_conflict'; end if;
    update private.push_subscriptions set disabled_at=clock_timestamp() where binding_id=item.binding_id;
  end if;
  if (select count(*) from private.push_subscriptions where user_id=p_user and disabled_at is null
    and (expires_at is null or expires_at>clock_timestamp()) and private.push_session_active(user_id,session_id))<16 then
    insert into private.push_subscriptions(binding_id,user_id,session_id,endpoint,endpoint_hash,p256dh,auth,expires_at)
      values(p_binding,p_user,p_session,p_endpoint,endpoint_key,p_p256dh,p_auth,p_expires);
  else raise exception 'rate_limited'; end if;
  return jsonb_build_object('binding_id',p_binding,'recipient_user_id',p_user,'enabled',true);
exception when unique_violation then raise exception 'binding_conflict';
end;
$$;

create function public.push_status(p_user uuid,p_session uuid,p_binding uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare item private.push_subscriptions;
begin
  perform private.require_push_member(p_user,p_session);
  select * into item from private.push_subscriptions where binding_id=p_binding;
  if found and (item.user_id<>p_user or item.session_id<>p_session) then raise exception 'push_forbidden'; end if;
  return jsonb_build_object('binding_id',p_binding,'recipient_user_id',p_user,'enabled',
    item.binding_id is not null and item.disabled_at is null and (item.expires_at is null or item.expires_at>clock_timestamp()));
end;
$$;

create function public.push_unsubscribe(p_user uuid,p_session uuid,p_binding uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare item private.push_subscriptions;
begin
  perform private.require_push_member(p_user,p_session);
  select * into item from private.push_subscriptions where binding_id=p_binding for update;
  if found and (item.user_id<>p_user or item.session_id<>p_session) then raise exception 'push_forbidden'; end if;
  update private.push_subscriptions set disabled_at=coalesce(disabled_at,clock_timestamp()) where binding_id=p_binding;
  return jsonb_build_object('enabled',false);
end;
$$;

-- Resolve the Auth recipient from the current profile kind and authorization.
-- Historical participation remains readable after disconnect, as in P10.
create function private.push_route(p_user uuid,p_session uuid,p_job uuid) returns jsonb
language plpgsql stable set search_path = '' as $$
declare job private.notification_jobs; recipient public.profiles;
begin
  if not private.push_session_active(p_user,p_session) or not exists(
    select 1 from private.memberships m join public.profiles p on p.id=m.user_id
      where m.user_id=p_user and p.auth_user_id=p_user and p.disabled_at is null) then return null; end if;
  select * into job from private.notification_jobs where id=p_job;
  if not found or job.created_at+interval '24 hours'<=clock_timestamp() then return null; end if;
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

create function public.push_resolve(p_user uuid,p_session uuid,p_delivery uuid,p_binding uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare item private.push_subscriptions; delivery private.push_deliveries; route jsonb;
begin
  perform private.require_push_member(p_user,p_session);
  select * into item from private.push_subscriptions where binding_id=p_binding;
  if not found or item.user_id<>p_user or item.session_id<>p_session or item.disabled_at is not null
    or (item.expires_at is not null and item.expires_at<=clock_timestamp()) then raise exception 'push_forbidden'; end if;
  select * into delivery from private.push_deliveries where id=p_delivery and binding_id=p_binding;
  if not found then raise exception 'push_forbidden'; end if;
  route:=private.push_route(p_user,p_session,delivery.job_id);
  if route is null then raise exception 'push_forbidden'; end if;
  return route;
end;
$$;

create function public.push_claim(p_limit integer default 10) returns jsonb
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
      if private.push_route(item.user_id,item.session_id,job.id) is not null then
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

create function public.push_prepare(p_delivery uuid,p_lease uuid) returns jsonb
language plpgsql set search_path = '' as $$
declare delivery private.push_deliveries; item private.push_subscriptions;
begin
  select * into delivery from private.push_deliveries where id=p_delivery for update;
  if not found or p_lease is null or delivery.status<>'leased' or delivery.lease_token is distinct from p_lease
    or delivery.lease_until is null or delivery.lease_until<=clock_timestamp() then return null; end if;
  select * into item from private.push_subscriptions where binding_id=delivery.binding_id;
  if item.disabled_at is not null or (item.expires_at is not null and item.expires_at<=clock_timestamp())
    or exists(select 1 from private.notification_jobs where id=delivery.job_id and created_at+interval '24 hours'<=clock_timestamp()+interval '30 seconds')
    or private.push_route(item.user_id,item.session_id,delivery.job_id) is null then
    update private.push_deliveries set status='cancelled',lease_token=null,lease_until=null where id=delivery.id;
    return null;
  end if;
  update private.push_deliveries set lease_until=clock_timestamp()+interval '30 seconds' where id=delivery.id;
  return jsonb_build_object('lease_remaining_ms',30000,'endpoint',item.endpoint,'keys',jsonb_build_object('p256dh',item.p256dh,'auth',item.auth),
    'payload',jsonb_build_object('version',1,'delivery_id',delivery.id,'binding_id',item.binding_id,'recipient_user_id',item.user_id));
end;
$$;

create function public.push_finish(p_delivery uuid,p_lease uuid,p_outcome text,p_code integer,p_retry_seconds integer default 30) returns boolean
language plpgsql set search_path = '' as $$
declare delivery private.push_deliveries;
begin
  if p_outcome is null or p_outcome not in ('sent','invalid','retry','failed') or p_code is null or p_code<0 or p_code>599
    or p_retry_seconds is null or p_retry_seconds<1 or p_retry_seconds>3600 then raise exception 'invalid_request'; end if;
  select * into delivery from private.push_deliveries where id=p_delivery for update;
  if not found or p_lease is null or delivery.status<>'leased' or delivery.lease_token is distinct from p_lease
    or delivery.lease_until is null or delivery.lease_until<=clock_timestamp() then return false; end if;
  update private.push_deliveries set
    status=case when p_outcome='sent' then 'sent' when p_outcome='retry' and attempts<5 then 'pending' else 'failed' end,
    sent_at=case when p_outcome='sent' then clock_timestamp() else null end,
    last_code=p_code,lease_token=null,lease_until=null,
    next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(p_retry_seconds,least(30*power(2,attempts-1)::integer,3600)))
    where id=delivery.id;
  if p_outcome='invalid' then
    update private.push_subscriptions set disabled_at=coalesce(disabled_at,clock_timestamp()) where binding_id=delivery.binding_id;
  end if;
  return true;
end;
$$;

revoke all on function private.require_push_member(uuid,uuid),private.push_route(uuid,uuid,uuid),
  public.push_subscribe(uuid,uuid,uuid,text,text,text,timestamptz),public.push_status(uuid,uuid,uuid),public.push_unsubscribe(uuid,uuid,uuid),
  public.push_resolve(uuid,uuid,uuid,uuid),public.push_claim(integer),public.push_prepare(uuid,uuid),public.push_finish(uuid,uuid,text,integer,integer)
  from public,anon,authenticated;
grant execute on function private.require_push_member(uuid,uuid),private.push_route(uuid,uuid,uuid),
  public.push_subscribe(uuid,uuid,uuid,text,text,text,timestamptz),public.push_status(uuid,uuid,uuid),public.push_unsubscribe(uuid,uuid,uuid),
  public.push_resolve(uuid,uuid,uuid,uuid),public.push_claim(integer),public.push_prepare(uuid,uuid),public.push_finish(uuid,uuid,text,integer,integer)
  to service_role;
