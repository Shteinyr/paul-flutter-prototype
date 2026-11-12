begin;
create function pg_temp.assert_true(v boolean,d text) returns void language plpgsql as $$begin if v is distinct from true then raise exception 'Assertion: %',d;end if;end;$$;
create function pg_temp.expect_error(s text,e text) returns void language plpgsql as $$begin begin execute s;exception when others then if position(e in sqlerrm)>0 then return;end if;raise;end;raise exception 'Expected %',e;end;$$;
insert into auth.users(id) select ('75000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,9)n;
insert into public.profiles(id,name,occupation,summary,skills,searching_skills)
select id,case right(id::text,1) when '1' then 'Viewer' when '2' then 'Julia' when '3' then 'Julia Robinson' when '4' then 'Anna Julia' when '5' then 'Julia Pending' when '6' then 'Julia Disabled' when '7' then 'Julia Deleted' when '8' then '100%_Back\slash' else 'Юлия Иванова' end,'Designer','Test',array['Marketing'],array[]::text[] from auth.users where id::text like '75000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '75000000-%' and right(id::text,1) not in ('5','6');

update public.profiles set deleted_at=now(),auth_user_id=null,name='Удалённый пользователь',occupation='',summary='',skills=array[]::text[],searching_skills=array[]::text[] where id='75000000-0000-4000-8000-000000000007';
insert into public.profiles(id,profile_kind,name,occupation,summary,skills,searching_skills) values('76000000-0000-4000-8000-000000000001','managed','Julia Managed','Designer','Test',array['Marketing'],array[]::text[]);
insert into public.profiles(id,profile_kind,name,occupation,summary,skills,searching_skills,disabled_at) values('76000000-0000-4000-8000-000000000002','managed','Julia Disabled','Designer','Test',array['Marketing'],array[]::text[],now());
select pg_temp.assert_true(not has_function_privilege('anon','public.profile_name_search(text,jsonb,integer)','execute'),'No anon grant');
select pg_temp.assert_true((select not prosecdef and proconfig=array['search_path=""'] from pg_proc where oid='public.profile_name_search(text,jsonb,integer)'::regprocedure),'Invoker with fixed search path');
insert into auth.sessions(id,user_id) values('75000000-1111-4111-8111-000000000001','75000000-0000-4000-8000-000000000001');
set local role anon;
select pg_temp.expect_error($q$select public.profile_name_search('Julia')$q$,'permission denied');
reset role;
set local role authenticated;
set local request.jwt.claim.sub='75000000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"session_id":"75000000-1111-4111-8111-000000000001"}';
select pg_temp.assert_true(jsonb_array_length(public.profile_name_search(' JULIA ')->'results')=4,'Global active registered and managed only');
select pg_temp.assert_true(public.profile_name_search('julia')->'results'->0->>'name'='Julia','Exact first');
select pg_temp.assert_true(public.profile_name_search('julia')->'results'->1->>'name'='Julia Managed','Prefixes before substring');
select pg_temp.assert_true(public.profile_name_search('julia')->'results'->3->>'name'='Anna Julia','Substring last');
select pg_temp.assert_true(public.profile_name_search('julia')->'results'->0->'matched_kinds'='[]'::jsonb,'Name results have no skill matches');
select pg_temp.assert_true(jsonb_array_length(public.profile_name_search('%_')->'results')=1,'Percent/underscore literal');
select pg_temp.assert_true(jsonb_array_length(public.profile_name_search(E'\\slash')->'results')=1,'Backslash literal');
select pg_temp.assert_true(jsonb_array_length(public.profile_name_search('ЮЛ')->'results')=1,'Unicode case insensitive');
select pg_temp.assert_true(jsonb_array_length(public.profile_name_search('viewer')->'results')=1,'Self included');
select pg_temp.assert_true(jsonb_array_length(public.profile_name_search('missing')->'results')=0,'Real empty');
select pg_temp.assert_true(public.profile_name_search('julia',public.profile_name_search('julia',null,1)->'next_cursor',1)->'results'->0->>'name'='Julia Managed','Keyset next page');
select pg_temp.expect_error($q$select public.profile_name_search('x')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.profile_name_search('julia',null,0)$q$,'invalid_request');
select pg_temp.expect_error($q$select public.profile_name_search('other',public.profile_name_search('julia',null,1)->'next_cursor')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.profile_name_search('julia','{"query":"julia","mode":"names","rank":3,"name":"Julia","after":"bad"}')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.profile_name_search('julia','[]')$q$,'invalid_request');

reset role;
insert into public.profiles(id,profile_kind,name,occupation,summary,skills,searching_skills)
select ('77000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'managed','Same Name','Designer','Test',array['Marketing'],array[]::text[] from generate_series(1,23)n;
set local role authenticated;
do $$declare first jsonb;second jsonb;begin
 first:=public.profile_name_search('same');
 second:=public.profile_name_search('same',first->'next_cursor');
 perform pg_temp.assert_true(jsonb_array_length(first->'results')=20 and jsonb_array_length(second->'results')=3,'Default pages20+3');
 perform pg_temp.assert_true(first->'results'->19->>'id'<second->'results'->0->>'id','Stable ID tie break without duplicate');
 perform pg_temp.assert_true(second->'next_cursor'='null'::jsonb,'Last page has no cursor');
end;$$;
set local request.jwt.claim.sub='75000000-0000-4000-8000-000000000005';
select pg_temp.expect_error($q$select public.profile_name_search('julia')$q$,'membership_required');
set local request.jwt.claim.sub='75000000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"is_anonymous":true}';
select pg_temp.expect_error($q$select public.profile_name_search('julia')$q$,'membership_required');
reset role;
rollback;
