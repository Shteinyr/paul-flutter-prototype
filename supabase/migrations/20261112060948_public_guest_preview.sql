-- Explicit public read contract. Anonymous callers never receive table/RPC grants.
-- The Edge handler may call only this service-role-only projection.
create function private.preview_visible(p_profile uuid) returns boolean
language sql stable security invoker set search_path='' as $$
  select exists(select 1 from public.profiles p where p.id=p_profile
    and p.disabled_at is null and p.deleted_at is null
    and (p.profile_kind='managed' or exists(
      select 1 from private.memberships m where m.user_id=p.id)));
$$;

create function private.preview_profile(p_profile uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('id',p.id,'name',p.name,'occupation',p.occupation,
    'summary',p.summary,'skills',p.skills,'searching_skills',p.searching_skills,
    'avatar_path',p.avatar_path,'contact_count',(
      select count(*) from public.connections c
      where (c.user_low=p.id and private.preview_visible(c.user_high))
        or (c.user_high=p.id and private.preview_visible(c.user_low))))
  from public.profiles p where p.id=p_profile and private.preview_visible(p.id);
$$;

create function private.preview_request(p_request uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('id',r.id,'skill',r.skill,'message',r.message,
    'created_at',r.created_at,'expires_at',r.expires_at,
    'author',private.preview_profile(r.author_profile_id))
  from public.community_requests r where r.id=p_request
    and r.expires_at>clock_timestamp() and private.preview_visible(r.author_profile_id);
$$;

create function public.public_preview(p_action text,p_query text default '',p_kind text default 'all',
  p_profile uuid default null,p_request uuid default null,p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare q text; after_id uuid; after_time timestamptz; page jsonb; next_cursor jsonb;
begin
  if p_action is null or p_action not in ('profiles','names','profile','feed','get')
    or p_kind is null or p_kind not in ('all','offering','hiring')
    or p_query is null or octet_length(p_query)>2048 or char_length(p_query)>200
    or p_limit is null or p_limit<1 or p_limit>20 then raise exception 'invalid_request'; end if;
  q:=lower(btrim(regexp_replace(p_query,'\s+',' ','g')));
  if p_action='profile' then
    if p_profile is null or p_cursor is not null then raise exception 'invalid_request'; end if;
    return jsonb_build_object('profile',private.preview_profile(p_profile));
  elsif p_action='get' then
    if p_request is null or p_cursor is not null then raise exception 'invalid_request'; end if;
    return jsonb_build_object('request',private.preview_request(p_request));
  elsif p_action in ('profiles','names') then
    if p_cursor is not null then
      if jsonb_typeof(p_cursor)<>'object' or (select count(*) from jsonb_object_keys(p_cursor))<>3
        or p_cursor->>'query' is distinct from q or p_cursor->>'kind' is distinct from p_kind
        or jsonb_typeof(p_cursor->'after') is distinct from 'string' then raise exception 'invalid_request'; end if;
      begin after_id:=(p_cursor->>'after')::uuid;
      exception when invalid_text_representation then raise exception 'invalid_request'; end;
      if after_id is null then raise exception 'invalid_request'; end if;
    end if;
    with matches as (
      select p.id,private.preview_profile(p.id) as item from public.profiles p
      where private.preview_visible(p.id) and (after_id is null or p.id>after_id)
        and (q='' or strpos(lower(p.name),q)>0 or (p_action='profiles' and exists(
          select 1 from unnest(case p_kind when 'offering' then p.skills
            when 'hiring' then p.searching_skills else p.skills||p.searching_skills end) s
          where strpos(lower(s),q)>0)))
      order by p.id limit p_limit+1)
    select coalesce(jsonb_agg(item order by id),'[]'::jsonb) into page from matches;
    if jsonb_array_length(page)>p_limit then
      page:=page-p_limit;
      next_cursor:=jsonb_build_object('after',page->(p_limit-1)->>'id','query',q,'kind',p_kind);
    end if;
    return jsonb_build_object('query',q,'kind',p_kind,'profiles',page,'next_cursor',next_cursor);
  else
    if p_cursor is not null then
      if jsonb_typeof(p_cursor)<>'object' or (select count(*) from jsonb_object_keys(p_cursor))<>2
        or jsonb_typeof(p_cursor->'created_at') is distinct from 'string'
        or jsonb_typeof(p_cursor->'id') is distinct from 'string' then raise exception 'invalid_request'; end if;
      begin
        after_time:=(p_cursor->>'created_at')::timestamptz;
        after_id:=(p_cursor->>'id')::uuid;
      exception when invalid_text_representation or invalid_datetime_format or datetime_field_overflow then
        raise exception 'invalid_request'; end;
      if after_time is null or after_id is null or not isfinite(after_time) then raise exception 'invalid_request'; end if;
    end if;
    with matches as (
      select r.id,r.created_at,private.preview_request(r.id) as item from public.community_requests r
      where r.expires_at>clock_timestamp() and private.preview_visible(r.author_profile_id)
        and (after_time is null or (r.created_at,r.id)<(after_time,after_id))
      order by r.created_at desc,r.id desc limit p_limit+1)
    select coalesce(jsonb_agg(item order by created_at desc,id desc),'[]'::jsonb) into page from matches;
    if jsonb_array_length(page)>p_limit then
      page:=page-p_limit;
      next_cursor:=jsonb_build_object('created_at',page->(p_limit-1)->>'created_at','id',page->(p_limit-1)->>'id');
    end if;
    return jsonb_build_object('requests',page,'next_cursor',next_cursor,'server_now',clock_timestamp());
  end if;
end;
$$;

revoke all on function private.preview_visible(uuid),private.preview_profile(uuid),private.preview_request(uuid),
  public.public_preview(text,text,text,uuid,uuid,jsonb,integer) from public,anon,authenticated;
grant execute on function private.preview_visible(uuid),private.preview_profile(uuid),private.preview_request(uuid),
  public.public_preview(text,text,text,uuid,uuid,jsonb,integer) to service_role;
