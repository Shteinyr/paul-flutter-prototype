-- Keep explicit name search separate from exact skill search. Bind cursors to their mode.
grant execute on function private.skill_key(text) to service_role;
create or replace function public.public_preview(p_action text,p_query text default '',p_kind text default 'all',
  p_profile uuid default null,p_request uuid default null,p_cursor jsonb default null,p_limit integer default 20)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare q text; after_id uuid; after_time timestamptz; page jsonb; next_cursor jsonb;
begin
  if p_action is null or p_action not in ('profiles','names','profile','feed','get')
    or p_kind is null or p_kind not in ('all','offering','hiring')
    or p_query is null or octet_length(p_query)>2048 or char_length(p_query)>200
    or p_limit is null or p_limit<1 or p_limit>20 then raise exception 'invalid_request'; end if;
  q:=private.skill_key(p_query);
  if p_action='profile' then
    if p_profile is null or p_cursor is not null then raise exception 'invalid_request'; end if;
    return jsonb_build_object('profile',private.preview_profile(p_profile));
  elsif p_action='get' then
    if p_request is null or p_cursor is not null then raise exception 'invalid_request'; end if;
    return jsonb_build_object('request',private.preview_request(p_request));
  elsif p_action in ('profiles','names') then
    if p_cursor is not null then
      if jsonb_typeof(p_cursor)<>'object' or (select count(*) from jsonb_object_keys(p_cursor))<>4
        or p_cursor->>'mode' is distinct from p_action
        or p_cursor->>'query' is distinct from q or p_cursor->>'kind' is distinct from p_kind
        or jsonb_typeof(p_cursor->'after') is distinct from 'string' then raise exception 'invalid_request'; end if;
      begin after_id:=(p_cursor->>'after')::uuid;
      exception when invalid_text_representation then raise exception 'invalid_request'; end;
      if after_id is null then raise exception 'invalid_request'; end if;
    end if;
    with matches as (
      select p.id,private.preview_profile(p.id) as item from public.profiles p
      where private.preview_visible(p.id) and (after_id is null or p.id>after_id)
        and (q='' or (p_action='names' and strpos(lower(p.name),q)>0)
          or (p_action='profiles' and exists(
            select 1 from unnest(case p_kind when 'offering' then p.skills
              when 'hiring' then p.searching_skills else p.skills||p.searching_skills end) s
            where private.skill_key(s)=q)))
      order by p.id limit p_limit+1)
    select coalesce(jsonb_agg(item order by id),'[]'::jsonb) into page from matches;
    if jsonb_array_length(page)>p_limit then
      page:=page-p_limit;
      next_cursor:=jsonb_build_object('after',page->(p_limit-1)->>'id','query',q,'kind',p_kind,'mode',p_action);
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
