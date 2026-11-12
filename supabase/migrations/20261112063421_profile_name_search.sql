-- Name reads use exactly the existing registered-member profile RLS audience.
create function public.profile_name_search(p_query text,p_cursor jsonb default null,p_limit integer default 20)
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
    into results from jsonb_array_elements(page) item;
  return jsonb_build_object('query',query_key,'kind','all','results',results,'next_cursor',next_cursor);
end;
$$;
revoke all on function public.profile_name_search(text,jsonb,integer) from public,anon,service_role;
grant execute on function public.profile_name_search(text,jsonb,integer) to authenticated;
