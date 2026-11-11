-- Depends on the MVP member/session and invited-registration guards.
-- Push enqueue/cancel hooks are supplied by the following push integration.
create table public.community_requests (
  id uuid primary key default gen_random_uuid(),
  author_profile_id uuid not null references public.profiles(id),
  skill text not null check (btrim(skill)<>'' and octet_length(skill)<=32768),
  message text not null check (btrim(message)<>'' and octet_length(message)<=65536),
  created_at timestamptz not null default clock_timestamp(),
  expires_at timestamptz not null default clock_timestamp()+interval '30 days',
  check (expires_at>created_at)
);
create index community_requests_feed_idx on public.community_requests(created_at desc,id desc);
create index community_requests_expiry_idx on public.community_requests(expires_at,id);
create index community_requests_author_idx on public.community_requests(author_profile_id);
alter table public.community_requests enable row level security;
revoke all on public.community_requests from public,anon,authenticated;
grant all on public.community_requests to service_role;

-- Receipts contain a digest and IDs, never the deleted request's text.
create table private.community_operations (
  actor_profile_id uuid not null references public.profiles(id),
  client_operation_id uuid not null,
  action text not null check (action in ('create','close')),
  request_id uuid not null,
  payload_hash text not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key(actor_profile_id,client_operation_id)
);
alter table private.community_operations enable row level security;
revoke all on private.community_operations from public,anon,authenticated;
grant all on private.community_operations to service_role;

create function private.community_payload(p_request uuid,p_actor uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object(
    'id',r.id,'skill',r.skill,'message',r.message,'created_at',r.created_at,
    'expires_at',r.expires_at,'is_author',r.author_profile_id=p_actor,
    'author',jsonb_build_object('id',p.id,'name',p.name,'occupation',p.occupation,'avatar_path',p.avatar_path)
  ) from public.community_requests r join public.profiles p on p.id=r.author_profile_id
  where r.id=p_request and r.expires_at>clock_timestamp()
    and p.disabled_at is null and p.deleted_at is null;
$$;

create function public.community_get(p_user uuid,p_session uuid,p_request uuid) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare item jsonb;
begin
  perform private.require_member_session(p_user,p_session);
  if p_request is null then raise exception 'invalid_request'; end if;
  item:=private.community_payload(p_request,p_user);
  return jsonb_build_object('request',item,'state',case when item is null then 'unavailable' else 'active' end);
end;
$$;

create function public.community_feed(p_user uuid,p_session uuid,p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare after_time timestamptz; after_id uuid; page jsonb; next_cursor jsonb;
begin
  perform private.require_member_session(p_user,p_session);
  if p_limit is null or p_limit<1 or p_limit>50 then raise exception 'invalid_request'; end if;
  if p_cursor is not null then
    if jsonb_typeof(p_cursor)<>'object' or (select count(*) from jsonb_object_keys(p_cursor))<>2
      or jsonb_typeof(p_cursor->'created_at') is distinct from 'string'
      or jsonb_typeof(p_cursor->'id') is distinct from 'string' then raise exception 'invalid_request'; end if;
    begin
      after_time:=(p_cursor->>'created_at')::timestamptz;
      after_id:=(p_cursor->>'id')::uuid;
      if not isfinite(after_time) then raise exception 'invalid_request'; end if;
    exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
      raise exception 'invalid_request';
    end;
  end if;
  select coalesce(jsonb_agg(item order by created_at desc,id desc) filter (where item is not null),'[]'::jsonb) into page from (
    select r.id,r.created_at,private.community_payload(r.id,p_user) as item
    from public.community_requests r join public.profiles p on p.id=r.author_profile_id
    where r.expires_at>clock_timestamp() and p.disabled_at is null and p.deleted_at is null
      and (after_time is null or (r.created_at,r.id)<(after_time,after_id))
    order by r.created_at desc,r.id desc limit p_limit+1
  ) items;
  if jsonb_array_length(page)>p_limit then
    page:=page-p_limit;
    next_cursor:=jsonb_build_object('created_at',page->(p_limit-1)->>'created_at','id',page->(p_limit-1)->>'id');
  end if;
  return jsonb_build_object('requests',page,'next_cursor',next_cursor,'server_now',clock_timestamp());
end;
$$;

create function public.community_create(p_user uuid,p_session uuid,p_operation uuid,p_skill text,p_message text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare receipt private.community_operations; fingerprint text; request uuid; skill text; message text; created timestamptz;
begin
  -- Serialize against account deletion and repeated commands from this author.
  perform 1 from public.profiles where id=p_user for update;
  perform private.require_member_session(p_user,p_session);
  perform private.require_community_publisher(p_user);
  skill:=btrim(regexp_replace(p_skill,U&'[\0009-\000D\0020\00A0\1680\2000-\200A\2028\2029\202F\205F\3000\FEFF]+',' ','g'));
  message:=btrim(p_message);
  if p_operation is null or skill is null or skill='' or octet_length(skill)>32768
    or message is null or message='' or octet_length(message)>65536 then raise exception 'invalid_request'; end if;
  fingerprint:=encode(sha256(convert_to(jsonb_build_array('create',skill,message)::text,'UTF8')),'hex');
  select * into receipt from private.community_operations where actor_profile_id=p_user and client_operation_id=p_operation;
  if found then
    if receipt.action<>'create' or receipt.payload_hash<>fingerprint then raise exception 'operation_id_conflict'; end if;
    return jsonb_build_object('request_id',receipt.request_id,'replayed',true,
      'state',case when private.community_payload(receipt.request_id,p_user) is null then 'unavailable' else 'active' end);
  end if;
  created:=clock_timestamp();
  insert into public.community_requests(author_profile_id,skill,message,created_at,expires_at)
    values(p_user,skill,message,created,created+interval '30 days') returning id into request;
  insert into private.community_operations(actor_profile_id,client_operation_id,action,request_id,payload_hash)
    values(p_user,p_operation,'create',request,fingerprint);
  perform private.enqueue_community_notifications(request);
  return jsonb_build_object('request_id',request,'state','active','replayed',false);
end;
$$;

create function public.community_close(p_user uuid,p_session uuid,p_operation uuid,p_request uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare receipt private.community_operations; request public.community_requests; fingerprint text;
begin
  perform 1 from public.profiles where id=p_user for update;
  perform private.require_member_session(p_user,p_session);
  if p_operation is null or p_request is null then raise exception 'invalid_request'; end if;
  fingerprint:=encode(sha256(convert_to(jsonb_build_array('close',p_request)::text,'UTF8')),'hex');
  select * into receipt from private.community_operations where actor_profile_id=p_user and client_operation_id=p_operation;
  if found then
    if receipt.action<>'close' or receipt.payload_hash<>fingerprint then raise exception 'operation_id_conflict'; end if;
    return jsonb_build_object('request_id',p_request,'state','unavailable','replayed',true);
  end if;
  select * into request from public.community_requests where id=p_request for update;
  if found and request.author_profile_id<>p_user then raise exception 'community_forbidden'; end if;
  perform private.cancel_community_notifications(p_request);
  delete from public.community_requests where id=p_request;
  insert into private.community_operations(actor_profile_id,client_operation_id,action,request_id,payload_hash)
    values(p_user,p_operation,'close',p_request,fingerprint);
  return jsonb_build_object('request_id',p_request,'state','unavailable','replayed',false);
end;
$$;

create function public.community_expire(p_limit integer default 200) returns integer
language plpgsql security invoker set search_path='' set statement_timeout='8s' as $$
declare request uuid; removed integer:=0;
begin
  if p_limit is null or p_limit<1 or p_limit>1000 then raise exception 'invalid_request'; end if;
  for request in select id from public.community_requests where expires_at<=clock_timestamp()
    order by expires_at,id for update skip locked limit p_limit loop
    perform private.cancel_community_notifications(request);
    delete from public.community_requests where id=request;
    removed:=removed+1;
  end loop;
  return removed;
end;
$$;

create function private.community_remove_for_author(p_author uuid) returns void
language plpgsql security invoker set search_path='' as $$
declare request uuid;
begin
  for request in select id from public.community_requests where author_profile_id=p_author for update loop
    perform private.cancel_community_notifications(request);
    delete from public.community_requests where id=request;
  end loop;
end;
$$;

revoke all on function private.community_payload(uuid,uuid),private.community_remove_for_author(uuid),
  public.community_get(uuid,uuid,uuid),public.community_feed(uuid,uuid,jsonb,integer),
  public.community_create(uuid,uuid,uuid,text,text),public.community_close(uuid,uuid,uuid,uuid),
  public.community_expire(integer) from public,anon,authenticated;
grant execute on function private.community_payload(uuid,uuid),private.community_remove_for_author(uuid),
  public.community_get(uuid,uuid,uuid),public.community_feed(uuid,uuid,jsonb,integer),
  public.community_create(uuid,uuid,uuid,text,text),public.community_close(uuid,uuid,uuid,uuid),
  public.community_expire(integer) to service_role;
