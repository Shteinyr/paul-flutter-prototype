-- Keep graph privileges behind a fixed viewer and a live Auth session.
create function private.search_viewer() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare viewer uuid:=auth.uid(); session_key text:=auth.jwt()->>'session_id';
begin
  if viewer is null or not private.is_member()
    or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
    raise exception 'membership_required' using errcode='42501';
  end if;
  if session_key is null or session_key !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' then
    raise exception 'session_revoked' using errcode='42501';
  end if;
  perform private.require_member_session(viewer,session_key::uuid);
  return viewer;
end;
$$;

create function private.mutual_contacts(p_target uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare viewer uuid:=private.search_viewer(); contacts jsonb; total bigint;
begin
  if p_target is null or p_target=viewer or not private.can_read_profile(p_target) then
    return jsonb_build_object('mutual_contacts','[]'::jsonb,'mutual_contact_count',0);
  end if;
  with own_contacts as (
    select case when user_low=viewer then user_high else user_low end as id
    from public.connections where user_low=viewer or user_high=viewer
  ), shared as (
    select p.id,p.name,p.occupation,p.avatar_path
    from own_contacts o join public.profiles p on p.id=o.id
    where p.id<>p_target and private.can_read_profile(p.id)
      and exists(select 1 from public.connections c
        where c.user_low=least(p.id,p_target) and c.user_high=greatest(p.id,p_target))
  ), bounded as (
    select * from shared order by lower(name) collate "C",id limit 3
  )
  select (select count(*) from shared),
    coalesce((select jsonb_agg(to_jsonb(bounded) order by lower(name) collate "C",id) from bounded),'[]'::jsonb)
    into total,contacts;
  return jsonb_build_object('mutual_contacts',contacts,'mutual_contact_count',total);
end;
$$;
revoke all on function private.search_viewer(),private.mutual_contacts(uuid) from public,anon,authenticated,service_role;
grant execute on function private.search_viewer(),private.mutual_contacts(uuid) to authenticated;

create or replace function public.skill_search(p_query text,p_kind text default 'all',p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare query_key text; after_id uuid; page jsonb; next_cursor jsonb;
begin
  perform private.search_viewer();
  query_key:=private.skill_search_query(p_query,p_kind,p_limit);
  if p_cursor is not null then
    if jsonb_typeof(p_cursor)<>'object' then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    if (select count(*) from jsonb_object_keys(p_cursor))<>3
      or p_cursor->>'query' is distinct from query_key or p_cursor->>'kind' is distinct from p_kind
      or jsonb_typeof(p_cursor->'after') is distinct from 'string'
      or (p_cursor->>'after') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    after_id:=(p_cursor->>'after')::uuid;
  end if;
  with visible as (
    select p.id,p.name,p.occupation,
      exists(select 1 from unnest(p.skills) s where private.skill_key(s)=query_key) as offering,
      exists(select 1 from unnest(p.searching_skills) s where private.skill_key(s)=query_key) as hiring
    from public.profiles p where p.disabled_at is null and (after_id is null or p.id>after_id)
  ), matches as (
    select id,name,occupation,array_remove(array[
      case when offering then 'offering' end,case when hiring then 'hiring' end],null) as matched_kinds
    from visible where case p_kind when 'offering' then offering when 'hiring' then hiring else offering or hiring end
    order by id limit p_limit+1
  )
  select coalesce(jsonb_agg(to_jsonb(matches) order by id),'[]'::jsonb) into page from matches;
  if jsonb_array_length(page)>p_limit then
    page:=page-p_limit;
    next_cursor:=jsonb_build_object('query',query_key,'kind',p_kind,'after',page->(p_limit-1)->>'id');
  end if;
  select coalesce(jsonb_agg(item || private.mutual_contacts((item->>'id')::uuid) order by ordinal),'[]'::jsonb) into page
    from jsonb_array_elements(page) with ordinality as rows(item,ordinal);
  return jsonb_build_object('query',query_key,'kind',p_kind,'results',page,'next_cursor',next_cursor);
end;
$$;


create or replace function public.profile_name_search(p_query text,p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare
  query_key text;
  after_rank integer;
  after_name text;
  after_id uuid;
  page jsonb;
  results jsonb;
  next_cursor jsonb;
begin
  perform private.search_viewer();
  perform private.skill_search_query(p_query,'all',p_limit);
  query_key:=lower(btrim(p_query));
  if char_length(query_key)<2 then
    raise exception 'invalid_request' using errcode='22023';
  end if;
  if p_cursor is not null then
    if jsonb_typeof(p_cursor)<>'object' then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    if (select count(*) from jsonb_object_keys(p_cursor))<>5
      or p_cursor->>'query' is distinct from query_key
      or p_cursor->>'mode' is distinct from 'names'
      or jsonb_typeof(p_cursor->'rank') is distinct from 'number'
      or (p_cursor->>'rank') not in ('0','1','2')
      or jsonb_typeof(p_cursor->'name') is distinct from 'string'
      or octet_length(p_cursor->>'name') not between 1 and 32768
      or jsonb_typeof(p_cursor->'after') is distinct from 'string'
      or (p_cursor->>'after') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then
      raise exception 'invalid_request' using errcode='22023';
    end if;
    after_rank:=(p_cursor->>'rank')::integer;
    after_name:=p_cursor->>'name';
    after_id:=(p_cursor->>'after')::uuid;
  end if;
  with visible as (
    select p.id,p.name,p.occupation,lower(p.name) as name_key,
      case when lower(p.name)=query_key then 0
        when starts_with(lower(p.name),query_key) then 1 else 2 end as rank
    from public.profiles p
    where p.disabled_at is null and p.deleted_at is null
      -- strpos treats %, _ and backslash literally, without LIKE escaping.
      and strpos(lower(p.name),query_key)>0
  ), matches as (
    select * from visible
    where after_id is null or (rank,name_key collate "C",id)>(after_rank,after_name collate "C",after_id)
    order by rank,name_key collate "C",id limit p_limit+1
  )
  select coalesce(jsonb_agg(to_jsonb(matches) order by rank,name_key collate "C",id),'[]'::jsonb)
    into page from matches;
  if jsonb_array_length(page)>p_limit then
    page:=page-p_limit;
    next_cursor:=jsonb_build_object('query',query_key,'mode','names',
      'rank',(page->(p_limit-1)->>'rank')::integer,
      'name',page->(p_limit-1)->>'name_key','after',page->(p_limit-1)->>'id');
  end if;
  select coalesce(jsonb_agg((item-'rank'-'name_key')||jsonb_build_object('matched_kinds','[]'::jsonb)),'[]'::jsonb)
    into results from jsonb_array_elements(page) with ordinality as rows(item,ordinal);
  select coalesce(jsonb_agg(item || private.mutual_contacts((item->>'id')::uuid) order by ordinal),'[]'::jsonb) into results
    from jsonb_array_elements(results) with ordinality as rows(item,ordinal);
  return jsonb_build_object('query',query_key,'kind','all','results',results,'next_cursor',next_cursor);
end;
$$;
