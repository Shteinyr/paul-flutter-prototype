begin;
create function pg_temp.assert_true(value boolean,description text) returns void language plpgsql as $$
begin
  if value is distinct from true then raise exception 'Assertion failed: %',description; end if;
end;
$$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)>0 then return; end if;
    raise;
  end;
  raise exception 'Expected failure %',expected;
end;
$$;
insert into auth.users(id) select ('50000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,5) n;
insert into private.memberships(user_id) select id from auth.users where id::text like '50000000-%' and id::text not like '%005';
insert into public.profiles(id,name,occupation,summary,skills,searching_skills) values
 ('50000000-0000-4000-8000-000000000001','Self','One','Test',array['Marketing','100% Quality'],array['Python']),
 ('50000000-0000-4000-8000-000000000002','Both','Two','Test',array['  MARKETING  ','marketing'],array[E'\tMarketing\n']),
 ('50000000-0000-4000-8000-000000000003','Digital','Three','Test',array[U&'\00A0Digital\2003Marketing\FEFF'],array['Design']),
 ('50000000-0000-4000-8000-000000000004','Hidden','Four','Test',array['Marketing','Hidden sentinel'],array['Hidden hiring']);
insert into public.profiles(id,profile_kind,name,occupation,summary,skills,searching_skills,disabled_at) values
 ('60000000-0000-4000-8000-000000000001','managed','Managed contact','M','Test',array['Marketing'],array['Managed hiring'],null),
 ('60000000-0000-4000-8000-000000000002','managed','Disabled contact','D','Test',array['Disabled sentinel','Marketing'],array['Disabled hiring'],now()),
 ('60000000-0000-4000-8000-000000000003','managed','Unassigned','U','Test',array['Unassigned sentinel'],array[]::text[],null);
insert into public.connections(user_low,user_high)
select '50000000-0000-4000-8000-000000000001'::uuid,id from public.profiles
where id in ('50000000-0000-4000-8000-000000000002','50000000-0000-4000-8000-000000000003',
 '60000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000002');
select pg_temp.assert_true(not has_function_privilege('anon','public.skill_suggest(text,text,integer)','execute'),'Anonymous cannot call suggest');
select pg_temp.assert_true(not has_function_privilege('anon','public.skill_search(text,text,jsonb,integer)','execute'),'Anonymous cannot call search');
select pg_temp.assert_true((select bool_and(not prosecdef and proconfig=array['search_path=""']) from pg_proc
 where oid in ('public.skill_search(text,text,jsonb,integer)'::regprocedure,'public.skill_suggest(text,text,integer)'::regprocedure)),
 'RPCs are invoker with fixed search_path');
select pg_temp.assert_true((select not exists(select 1 from aclexplode(coalesce(proacl,acldefault('f',proowner))) where grantee=0)
 from pg_proc where oid='public.skill_search(text,text,jsonb,integer)'::regprocedure),'No default PUBLIC execute');
insert into auth.sessions(id,user_id) values('50000000-1111-4111-8111-000000000001','50000000-0000-4000-8000-000000000001');
set local role anon;
select pg_temp.expect_error($q$select public.skill_suggest('mark')$q$,'permission denied');
reset role;
set local role authenticated;
set local request.jwt.claim.sub='50000000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"session_id":"50000000-1111-4111-8111-000000000001"}';
select pg_temp.assert_true(private.skill_key(U&'\00A0Digital\2003\0009Marketing\FEFF')='digital marketing','Unicode whitespace follows saved server free-text semantics');
select pg_temp.assert_true(jsonb_array_length(public.skill_search(' marketing ')->'results')=4,'All includes every active registered and managed profile once');
select pg_temp.assert_true(jsonb_array_length(public.skill_search('Marketing','offering')->'results')=4,'Offering uses all active saved skills');
select pg_temp.assert_true(jsonb_array_length(public.skill_search('MARKETING','hiring')->'results')=1,'Hiring uses searching_skills');
select pg_temp.assert_true(public.skill_search('marketing')->'results'->1->'matched_kinds'='["offering","hiring"]'::jsonb,'Double match retains both kinds without duplicate row');
select pg_temp.assert_true(jsonb_array_length(public.skill_search('digital marketing')->'results')=1,'Digital Marketing stays separate');
select pg_temp.assert_true(jsonb_array_length(public.skill_search('unknown')->'results')=0,'Unknown exact skill returns real empty');
select pg_temp.assert_true(public.skill_suggest('mar')->'suggestions'->0->>'key'='marketing','Prefix precedes substring');
select pg_temp.assert_true(public.skill_suggest('mar')->'suggestions'->1->>'key'='digital marketing','Separate substring suggestion');
select pg_temp.assert_true(jsonb_array_length(public.skill_suggest('marketing','hiring')->'suggestions')=1,'Suggest uses selected kind');
select pg_temp.assert_true(jsonb_array_length(public.skill_suggest('sentinel')->'suggestions')=2,'Global active member and unassigned managed hints are visible, disabled hints are excluded');
select pg_temp.assert_true(jsonb_array_length(public.skill_suggest('%')->'suggestions')=1,'Percent is literal, never wildcard');
select pg_temp.assert_true(public.skill_search('Marketing','all',null,1)->'results'->0->>'name'='Self','First page stable UUID ASC');
select pg_temp.assert_true(public.skill_search('marketing','all',public.skill_search('Marketing','all',null,1)->'next_cursor',1)->'results'->0->>'name'='Both','Second page does not repeat first');
select pg_temp.assert_true(public.skill_search('marketing','all',
 public.skill_search('marketing','all',public.skill_search('marketing','all',null,1)->'next_cursor',1)->'next_cursor',1)->'results'->0->>'name'='Hidden','Third page includes the active member outside current contacts');
select pg_temp.assert_true(public.skill_search('marketing','all',
 public.skill_search('marketing','all',public.skill_search('marketing','all',public.skill_search('marketing','all',null,1)->'next_cursor',1)->'next_cursor',1)->'next_cursor',1)->'next_cursor'='null'::jsonb,'Last global page ends with no cursor');
select pg_temp.expect_error($q$select public.skill_search('python','all',public.skill_search('marketing','all',null,1)->'next_cursor')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_search('marketing','hiring',public.skill_search('marketing','all',null,1)->'next_cursor')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_search('marketing','all','[]')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_search('marketing','all','{"query":"marketing","kind":"all","after":"bad"}')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_search('marketing','all','{"query":"marketing","kind":"all"}')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_search('marketing','all',null,51)$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_search('marketing',null)$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_suggest('   ')$q$,'invalid_request');
select pg_temp.expect_error($q$select public.skill_suggest(repeat('x',32769))$q$,'invalid_request');
set local request.jwt.claim.sub='50000000-0000-4000-8000-000000000005';
select pg_temp.expect_error($q$select public.skill_search('Marketing')$q$,'membership_required');
select pg_temp.expect_error($q$select public.skill_suggest('Marketing')$q$,'membership_required');
set local request.jwt.claim.sub='70000000-0000-4000-8000-000000000001';
select pg_temp.expect_error($q$select public.skill_search('Marketing')$q$,'membership_required');
set local request.jwt.claim.sub='50000000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"is_anonymous":true}';
select pg_temp.expect_error($q$select public.skill_search('Marketing')$q$,'membership_required');
select pg_temp.expect_error($q$select public.skill_suggest('Marketing')$q$,'membership_required');
set local request.jwt.claims='{"session_id":"50000000-1111-4111-8111-000000000001"}';
reset role;
update public.profiles set searching_skills='{}' where id='50000000-0000-4000-8000-000000000002';
delete from public.connections where user_high='60000000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.assert_true(jsonb_array_length(public.skill_search('marketing','hiring')->'results')=0,'Removed hiring stops matching immediately');
select pg_temp.assert_true(jsonb_array_length(public.skill_suggest('marketing','hiring')->'suggestions')=0,'Removed hiring disappears from catalogue');
select pg_temp.assert_true(jsonb_array_length(public.skill_search('marketing')->'results')=4,'Disconnect preserves global active profile results');
select pg_temp.assert_true(jsonb_array_length(public.skill_suggest('Managed hiring')->'suggestions')=1,'Disconnect preserves global active hints');
reset role;
select pg_temp.assert_true((select skills=array['  MARKETING  ','marketing'] from public.profiles where id='50000000-0000-4000-8000-000000000002'),'Legacy stored strings remain unchanged');
rollback;
