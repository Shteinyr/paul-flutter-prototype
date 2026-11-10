-- Depends on P11's auth_user_id/profile_kind/disabled_at compatibility migration.
-- Read-time keys keep existing free-text arrays and profile identities intact.
create function private.skill_key(value text) returns text
language sql immutable strict set search_path = '' as $$
  select lower(btrim(regexp_replace(value,
    U&'[\0009-\000D\0020\00A0\1680\2000-\200A\2028\2029\202F\205F\3000\FEFF]+', ' ', 'g')));
$$;

create function private.skill_search_query(p_query text,p_kind text,p_limit integer) returns text
language plpgsql stable security invoker set search_path = '' as $$
declare query_key text;
begin
  if auth.uid() is null or not private.is_member()
    or coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then
    raise exception 'membership_required' using errcode='42501';
  end if;
  if p_query is null or octet_length(p_query)>32768
    or p_kind is null or p_kind not in ('all','offering','hiring')
    or p_limit is null or p_limit<1 or p_limit>50 then
    raise exception 'invalid_request' using errcode='22023';
  end if;
  query_key:=private.skill_key(p_query);
  if query_key='' then raise exception 'invalid_request' using errcode='22023'; end if;
  return query_key;
end;
$$;

create function public.skill_suggest(p_query text,p_kind text default 'all',p_limit integer default 10)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare query_key text; suggestions jsonb;
begin
  query_key:=private.skill_search_query(p_query,p_kind,p_limit);
  -- Both catalogue and results run as the caller under profiles_read RLS.
  -- Admin assignment never becomes an implicit search audience.
  with saved as (
    select s.value,private.skill_key(s.value) as key
    from public.profiles p cross join lateral unnest(
      case p_kind when 'offering' then p.skills when 'hiring' then p.searching_skills
        else p.skills || p.searching_skills end
    ) s(value) where p.disabled_at is null
  ), catalogue as (
    select key,min(value collate "C") as label from saved
    where key<>'' and strpos(key,query_key)>0 group by key
  ), page as (
    select key,label from catalogue
    order by case when key=query_key then 0 when starts_with(key,query_key) then 1 else 2 end,
      key collate "C" limit p_limit
  )
  select coalesce(jsonb_agg(to_jsonb(page)), '[]'::jsonb) into suggestions from page;
  return jsonb_build_object('query',query_key,'kind',p_kind,'suggestions',suggestions);
end;
$$;

create function public.skill_search(p_query text,p_kind text default 'all',p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare query_key text; after_id uuid; page jsonb; next_cursor jsonb;
begin
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
  return jsonb_build_object('query',query_key,'kind',p_kind,'results',page,'next_cursor',next_cursor);
end;
$$;

revoke all on function private.skill_key(text),private.skill_search_query(text,text,integer),
  public.skill_suggest(text,text,integer),public.skill_search(text,text,jsonb,integer) from public,anon,service_role;
grant execute on function private.skill_key(text),private.skill_search_query(text,text,integer),
  public.skill_suggest(text,text,integer),public.skill_search(text,text,jsonb,integer) to authenticated;
