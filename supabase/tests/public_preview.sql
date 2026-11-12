begin;
insert into auth.users(id) values
 ('71000000-0000-4000-8000-000000000001'),('71000000-0000-4000-8000-000000000002'),
 ('71000000-0000-4000-8000-000000000003'),('71000000-0000-4000-8000-000000000004'),
 ('71000000-0000-4000-8000-000000000005');
insert into public.profiles(id,name,occupation,summary,skills,searching_skills) values
 ('71000000-0000-4000-8000-000000000001','Preview Alice','Designer','Public',array['Design'],array['Marketing']),
 ('71000000-0000-4000-8000-000000000002','Preview Bob','Engineer','Public',array['Flutter'],array['Design']),
 ('71000000-0000-4000-8000-000000000003','Hidden pending','Engineer','Private',array['Flutter'],'{}'),
 ('71000000-0000-4000-8000-000000000004','Hidden disabled','Engineer','Private',array['Flutter'],'{}'),
 ('71000000-0000-4000-8000-000000000005','Hidden deleted','Engineer','Private',array['Flutter'],'{}');
insert into public.profiles(id,profile_kind,auth_user_id,name,occupation,summary,skills,searching_skills)
 values('71000000-0000-4000-8000-000000000006','managed',null,'Preview Design Fan','Singer','Public',array['Singing'],'{}');
insert into private.memberships(user_id) values
 ('71000000-0000-4000-8000-000000000001'),('71000000-0000-4000-8000-000000000002'),
 ('71000000-0000-4000-8000-000000000004'),('71000000-0000-4000-8000-000000000005');
update public.profiles set profile_kind='managed',auth_user_id=null,disabled_at=clock_timestamp()
 where id='71000000-0000-4000-8000-000000000004';
update public.profiles set deleted_at=clock_timestamp(),profile_kind='managed',auth_user_id=null,
 name='Удалённый пользователь',occupation='',summary='',skills='{}',searching_skills='{}',avatar_path=null
 where id='71000000-0000-4000-8000-000000000005';
insert into public.community_requests(id,author_profile_id,skill,message,created_at,expires_at) values
 ('72000000-0000-4000-8000-000000000001','71000000-0000-4000-8000-000000000001','Design','Active request',clock_timestamp(),clock_timestamp()+interval '1 day'),
 ('72000000-0000-4000-8000-000000000002','71000000-0000-4000-8000-000000000001','Design','Expired request',clock_timestamp()-interval '31 days',clock_timestamp()-interval '1 day'),
 ('72000000-0000-4000-8000-000000000003','71000000-0000-4000-8000-000000000004','Design','Disabled author',clock_timestamp(),clock_timestamp()+interval '1 day');
do $$
declare result jsonb;
begin
 result:=public.public_preview('profiles');
 if jsonb_array_length(result->'profiles')<>3 then raise exception 'active membership/managed boundary failed'; end if;
 if public.public_preview('profile',p_profile=>'71000000-0000-4000-8000-000000000003')->'profile' is distinct from 'null'::jsonb then raise exception 'pending profile leaked'; end if;
 if public.public_preview('profile',p_profile=>'71000000-0000-4000-8000-000000000005')->'profile' is distinct from 'null'::jsonb then raise exception 'deleted profile leaked'; end if;
 if jsonb_array_length(public.public_preview('names','Design')->'profiles')<>1 then raise exception 'name search included skill-only matches';end if;
 if jsonb_array_length(public.public_preview('profiles','Design')->'profiles')<>2 then raise exception 'skill search included name-only matches';end if;
 result:=public.public_preview('profiles','Flutter','offering');
 if jsonb_array_length(result->'profiles')<>1 then raise exception 'skill query failed'; end if;
 result:=public.public_preview('feed');
 if jsonb_array_length(result->'requests')<>1 then raise exception 'expired/disabled hiring leaked'; end if;
 if public.public_preview('get',p_request=>'72000000-0000-4000-8000-000000000002')->'request' is distinct from 'null'::jsonb then raise exception 'expired request leaked'; end if;
 begin perform public.public_preview('delete');raise exception 'write action accepted';exception when raise_exception then if sqlerrm<>'invalid_request' then raise; end if;end;
 result:=public.public_preview('profiles',p_limit=>1);
 if jsonb_array_length(public.public_preview('profiles',p_cursor=>result->'next_cursor')->'profiles')<>2 then raise exception 'pagination failed';end if;
end;
$$;
set local role anon;
do $$ begin
 begin perform public.public_preview('profiles');raise exception 'anonymous RPC privilege leaked';exception when insufficient_privilege then null;end;
 begin perform * from public.profiles;raise exception 'anonymous table privilege leaked';exception when insufficient_privilege then null;end;
end; $$;
reset role;
set local role authenticated;
do $$ begin
 begin perform public.public_preview('profiles');raise exception 'authenticated direct RPC privilege leaked';exception when insufficient_privilege then null;end;
 if exists(select 1 from public.profiles) then raise exception 'nonmember RLS boundary widened';end if;
end; $$;
reset role;
set local role service_role;
select public.public_preview('profiles','Preview')->>'kind';
reset role;
rollback;
