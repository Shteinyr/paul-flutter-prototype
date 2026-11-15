-- Requires 20261115045020 session admission. No cron or provider activation.
create table private.native_push_bindings (
  binding_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  session_id uuid not null,
  platform text not null check(platform in ('ios','android')),
  token text not null check(octet_length(token) between 20 and 4096),
  token_hash text not null check(token_hash ~ '^[a-f0-9]{64}$'),
  generation integer not null default 1 check(generation > 0),
  bound_at timestamptz not null default clock_timestamp(),
  disabled_at timestamptz
);
create unique index native_push_token_active_idx on private.native_push_bindings(token_hash) where disabled_at is null;
create index native_push_user_session_idx on private.native_push_bindings(user_id,session_id) where disabled_at is null;
alter table private.native_push_bindings enable row level security;
revoke all on private.native_push_bindings from public,anon,authenticated;
grant all on private.native_push_bindings to service_role;

create table private.native_push_deliveries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references private.notification_jobs(id),
  binding_id uuid not null references private.native_push_bindings(binding_id) on delete cascade,
  status text not null default 'pending' check(status in ('pending','leased','sent','invalid','failed','cancelled')),
  attempts integer not null default 0 check(attempts >= 0),
  bound_generation integer,
  next_attempt_at timestamptz not null default clock_timestamp(),
  lease_token uuid,
  lease_until timestamptz,
  last_code integer,
  unique(job_id,binding_id)
);
create index native_push_pending_idx on private.native_push_deliveries(next_attempt_at,id) where status in ('pending','leased');
alter table private.native_push_deliveries enable row level security;
revoke all on private.native_push_deliveries from public,anon,authenticated;
grant all on private.native_push_deliveries to service_role;
alter table private.notification_jobs add column native_push_expanded_at timestamptz;
create index native_push_unexpanded_idx on private.notification_jobs(created_at,id) where native_push_expanded_at is null;

create function private.native_push_allowed(p_user uuid,p_session uuid) returns boolean
language sql stable security invoker set search_path='' as $$
 select private.member_session_admitted(p_user,p_session)
   and exists(select 1 from private.memberships m join public.profiles p on p.id=m.user_id
     where m.user_id=p_user and p.auth_user_id=p_user and p.profile_kind='member'
       and p.disabled_at is null and p.deleted_at is null);
$$;

create function public.native_push_subscribe(p_user uuid,p_session uuid,p_binding uuid,
 p_token text,p_token_hash text,p_platform text) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare item private.native_push_bindings; canonical private.native_push_bindings; rotated boolean;
begin
 perform 1 from public.profiles where id=p_user for share;
 if not private.native_push_allowed(p_user,p_session) then raise exception 'session_admission_required'; end if;
 if p_binding is null or p_token is null or octet_length(p_token) not between 20 and 4096
   or p_token_hash is null or p_token_hash !~ '^[a-f0-9]{64}$'
   or p_platform not in ('ios','android') or p_platform is null then raise exception 'invalid_request'; end if;
 -- Fixed user -> token -> binding order protects capacity and concurrent rotation.
 perform pg_advisory_xact_lock(hashtextextended(p_user::text,150));
 select * into item from private.native_push_bindings where binding_id=p_binding;
 perform pg_advisory_xact_lock(hashtextextended(least(coalesce(item.token_hash,p_token_hash),p_token_hash),151));
 if item.token_hash is not null and item.token_hash<>p_token_hash then
   perform pg_advisory_xact_lock(hashtextextended(greatest(item.token_hash,p_token_hash),151));
 end if;
 select * into item from private.native_push_bindings where binding_id=p_binding for update;
 if found and (item.user_id<>p_user or item.session_id<>p_session or item.platform<>p_platform) then
   raise exception 'push_forbidden';
 end if;
 select * into canonical from private.native_push_bindings where token_hash=p_token_hash
   and user_id=p_user and session_id=p_session and platform=p_platform and disabled_at is null;
 if found and canonical.binding_id<>p_binding then
   return jsonb_build_object('recipient_user_id',p_user,'session_id',p_session,'binding_id',canonical.binding_id,'enabled',true);
 end if;
 if item.binding_id is null and (select count(*) from private.native_push_bindings b
   where b.user_id=p_user and b.disabled_at is null and private.native_push_allowed(b.user_id,b.session_id))>=16 then
   raise exception 'rate_limited';
 end if;
 -- A device token is a capability. Rotation/account switch retires its previous binding.
 update private.native_push_bindings set disabled_at=clock_timestamp()
   where token_hash=p_token_hash and binding_id<>p_binding and disabled_at is null;
 rotated:=item.binding_id is not null and (item.token_hash<>p_token_hash or item.disabled_at is not null);
 insert into private.native_push_bindings(binding_id,user_id,session_id,platform,token,token_hash)
 values(p_binding,p_user,p_session,p_platform,p_token,p_token_hash)
 on conflict(binding_id) do update set token=excluded.token,token_hash=excluded.token_hash,
   generation=private.native_push_bindings.generation+case when rotated then 1 else 0 end,
   disabled_at=null;
 if rotated then
   update private.native_push_deliveries set status='pending',lease_token=null,lease_until=null,next_attempt_at=clock_timestamp()
     where binding_id=p_binding and status in ('pending','leased');
 end if;
 return jsonb_build_object('recipient_user_id',p_user,'session_id',p_session,'binding_id',p_binding,'enabled',true);
end;$$;

create function public.native_push_unsubscribe(p_user uuid,p_session uuid,p_binding uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
 if not private.native_push_allowed(p_user,p_session) then raise exception 'session_admission_required'; end if;
 if exists(select 1 from private.native_push_bindings where binding_id=p_binding and (user_id<>p_user or session_id<>p_session)) then
   raise exception 'push_forbidden';
 end if;
 update private.native_push_bindings set disabled_at=coalesce(disabled_at,clock_timestamp())
   where binding_id=p_binding and user_id=p_user and session_id=p_session;
 update private.native_push_deliveries set status='cancelled',lease_token=null,lease_until=null
   where binding_id=p_binding and status in ('pending','leased');
end;$$;

create function public.native_push_resolve(p_user uuid,p_session uuid,p_binding uuid,p_delivery uuid) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare job uuid; route jsonb;
begin
 if not private.native_push_allowed(p_user,p_session) then raise exception 'session_admission_required'; end if;
 select d.job_id into job from private.native_push_deliveries d join private.native_push_bindings b on b.binding_id=d.binding_id
   where d.id=p_delivery and b.binding_id=p_binding and b.user_id=p_user and b.session_id=p_session and b.disabled_at is null;
 if not found then raise exception 'push_forbidden'; end if;
 route:=private.push_route(p_user,p_session,job);
 if route is null then raise exception 'push_forbidden'; end if;
 return route;
end;$$;

create function public.native_push_claim(p_limit integer default 4) returns jsonb
language plpgsql security invoker set search_path='' set statement_timeout='8s' as $$
declare job private.notification_jobs; binding private.native_push_bindings; delivery private.native_push_deliveries;
 result jsonb:='[]'::jsonb; fence uuid;
begin
 if p_limit is null or p_limit<1 or p_limit>20 then raise exception 'invalid_request'; end if;
 for job in select * from private.notification_jobs where native_push_expanded_at is null
   order by created_at,id for update skip locked limit 20 loop
   if job.created_at+interval '24 hours'>clock_timestamp()+interval '30 seconds' then
     for binding in select b.* from private.native_push_bindings b join public.profiles p on p.id=job.recipient_user_id
       where b.disabled_at is null and b.bound_at<=job.created_at
         and ((p.profile_kind='member' and b.user_id=p.auth_user_id) or
           (p.profile_kind='managed' and exists(select 1 from private.managed_profile_grants g
             where g.profile_id=p.id and g.user_id=b.user_id and g.can_reply and g.revoked_at is null))) loop
       if private.native_push_allowed(binding.user_id,binding.session_id)
         and private.push_dispatch_allowed(binding.user_id,binding.session_id,job.id) then
         insert into private.native_push_deliveries(job_id,binding_id) values(job.id,binding.binding_id) on conflict do nothing;
       end if;
     end loop;
   end if;
   update private.notification_jobs set native_push_expanded_at=clock_timestamp() where id=job.id;
 end loop;
 for delivery in select * from private.native_push_deliveries
   where (status='pending' and next_attempt_at<=clock_timestamp()) or (status='leased' and lease_until<=clock_timestamp())
   order by next_attempt_at,id for update skip locked limit p_limit loop
   select * into binding from private.native_push_bindings where binding_id=delivery.binding_id;
   if delivery.attempts>=5 then
     update private.native_push_deliveries set status='failed',lease_token=null,lease_until=null where id=delivery.id;
   elsif binding.disabled_at is not null or not private.native_push_allowed(binding.user_id,binding.session_id)
     or not private.push_dispatch_allowed(binding.user_id,binding.session_id,delivery.job_id)
     or exists(select 1 from private.notification_jobs where id=delivery.job_id and created_at+interval '24 hours'<=clock_timestamp()+interval '30 seconds') then
     update private.native_push_deliveries set status='cancelled',lease_token=null,lease_until=null where id=delivery.id;
   else
     fence:=gen_random_uuid();
     update private.native_push_deliveries set status='leased',attempts=attempts+1,bound_generation=binding.generation,
       lease_token=fence,lease_until=clock_timestamp()+interval '60 seconds' where id=delivery.id;
     result:=result||jsonb_build_array(jsonb_build_object('delivery_id',delivery.id,'lease_token',fence));
   end if;
 end loop;
 return result;
end;$$;

create function public.native_push_prepare(p_delivery uuid,p_lease uuid) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare delivery private.native_push_deliveries; binding private.native_push_bindings; job private.notification_jobs;
begin
 select * into delivery from private.native_push_deliveries where id=p_delivery for update;
 if not found or delivery.status<>'leased' or p_lease is null or delivery.lease_token is distinct from p_lease
   or delivery.lease_until<=clock_timestamp() then return null; end if;
 select * into binding from private.native_push_bindings where binding_id=delivery.binding_id;
 select * into job from private.notification_jobs where id=delivery.job_id;
 if binding.disabled_at is not null or binding.generation<>delivery.bound_generation
   or not private.native_push_allowed(binding.user_id,binding.session_id)
   or not private.push_dispatch_allowed(binding.user_id,binding.session_id,job.id)
   or job.created_at+interval '24 hours'<=clock_timestamp()+interval '30 seconds' then
   update private.native_push_deliveries set status='cancelled',lease_token=null,lease_until=null where id=delivery.id;
   return null;
 end if;
 update private.native_push_deliveries set lease_until=clock_timestamp()+interval '30 seconds' where id=delivery.id;
 return jsonb_build_object('lease_remaining_ms',30000,'token',binding.token,'platform',binding.platform,
   'payload',jsonb_build_object('version',1,'delivery_id',delivery.id,'binding_id',binding.binding_id,
     'recipient_user_id',binding.user_id,'kind',job.kind));
end;$$;

create function public.native_push_finish(p_delivery uuid,p_lease uuid,p_outcome text,p_code integer,p_retry_seconds integer default 30) returns boolean
language plpgsql security invoker set search_path='' as $$
declare delivery private.native_push_deliveries; binding private.native_push_bindings;
begin
 if p_outcome not in ('sent','invalid','retry','failed') or p_outcome is null then raise exception 'invalid_request'; end if;
 select * into delivery from private.native_push_deliveries where id=p_delivery for update;
 if not found or delivery.status<>'leased' or p_lease is null or delivery.lease_token is distinct from p_lease
   or delivery.lease_until<=clock_timestamp() then return false; end if;
 select * into binding from private.native_push_bindings where binding_id=delivery.binding_id;
 if binding.disabled_at is not null or binding.generation<>delivery.bound_generation
   or not private.native_push_allowed(binding.user_id,binding.session_id)
   or not private.push_dispatch_allowed(binding.user_id,binding.session_id,delivery.job_id) then
   update private.native_push_deliveries set status='cancelled',lease_token=null,lease_until=null where id=delivery.id;
   return false;
 end if;
 update private.native_push_deliveries set status=case when p_outcome='retry' and attempts<5 then 'pending'
     when p_outcome='retry' then 'failed' else p_outcome end,
   next_attempt_at=clock_timestamp()+make_interval(secs=>greatest(30,least(coalesce(p_retry_seconds,30),3600))),
   lease_token=null,lease_until=null,last_code=p_code where id=delivery.id;
 if p_outcome='invalid' then
   update private.native_push_bindings set disabled_at=clock_timestamp() where binding_id=binding.binding_id;
 end if;
 return true;
end;$$;

-- Hiring must enqueue for native-only users as well as existing Web Push users.
create or replace function private.enqueue_community_notifications(p_request uuid) returns void
language plpgsql security invoker set search_path='' as $$
declare request public.community_requests;
begin
 select * into request from public.community_requests where id=p_request;
 if not found or request.expires_at<=clock_timestamp() then return; end if;
 insert into private.notification_jobs(kind,request_id,recipient_user_id,created_at)
 select 'community_created',request.id,p.id,request.created_at from public.profiles p join private.memberships m on m.user_id=p.id
 where p.profile_kind='member' and p.auth_user_id=p.id and p.deleted_at is null and p.disabled_at is null
   and (exists(select 1 from private.push_subscriptions s where s.user_id=p.id and s.disabled_at is null
     and s.bound_at<=request.created_at and (s.expires_at is null or s.expires_at>clock_timestamp())
     and private.member_session_admitted(s.user_id,s.session_id))
   or exists(select 1 from private.native_push_bindings b where b.user_id=p.id and b.disabled_at is null
     and b.bound_at<=request.created_at and private.native_push_allowed(b.user_id,b.session_id)))
 on conflict(request_id,recipient_user_id) where kind='community_created' do nothing;
end;$$;

create or replace function private.cancel_community_notifications(p_request uuid) returns void
language plpgsql security invoker set search_path='' as $$
begin
 update private.notification_jobs set push_expanded_at=coalesce(push_expanded_at,clock_timestamp()),
   native_push_expanded_at=coalesce(native_push_expanded_at,clock_timestamp()) where kind='community_created' and request_id=p_request;
 update private.push_deliveries set status='cancelled',lease_token=null,lease_until=null where status in ('pending','leased')
   and job_id in(select id from private.notification_jobs where kind='community_created' and request_id=p_request);
 update private.native_push_deliveries set status='cancelled',lease_token=null,lease_until=null where status in ('pending','leased')
   and job_id in(select id from private.notification_jobs where kind='community_created' and request_id=p_request);
end;$$;

revoke all on function private.native_push_allowed(uuid,uuid),
 public.native_push_subscribe(uuid,uuid,uuid,text,text,text),public.native_push_unsubscribe(uuid,uuid,uuid),
 public.native_push_resolve(uuid,uuid,uuid,uuid),public.native_push_claim(integer),public.native_push_prepare(uuid,uuid),
 public.native_push_finish(uuid,uuid,text,integer,integer) from public,anon,authenticated;
grant execute on function private.native_push_allowed(uuid,uuid),
 public.native_push_subscribe(uuid,uuid,uuid,text,text,text),public.native_push_unsubscribe(uuid,uuid,uuid),
 public.native_push_resolve(uuid,uuid,uuid,uuid),public.native_push_claim(integer),public.native_push_prepare(uuid,uuid),
 public.native_push_finish(uuid,uuid,text,integer,integer) to service_role;

create function private.native_push_profile_lifecycle() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 if old.profile_kind='member' and (new.disabled_at is not null or new.deleted_at is not null) then
   delete from private.native_push_bindings where user_id=new.id;
 end if;
 return new;
end;$$;
create trigger native_push_profile_lifecycle after update of disabled_at,deleted_at on public.profiles
 for each row execute function private.native_push_profile_lifecycle();
revoke all on function private.native_push_profile_lifecycle() from public,anon,authenticated;
grant execute on function private.native_push_profile_lifecycle() to service_role;
