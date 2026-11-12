begin;
create function pg_temp.assert_true(v boolean,d text) returns void language plpgsql as $$begin if v is distinct from true then raise exception 'Assertion: %',d;end if;end;$$;
create function pg_temp.expect_error(s text,e text) returns void language plpgsql as $$begin begin execute s;exception when others then if position(e in sqlerrm)>0 then return;end if;raise;end;raise exception 'Expected %',e;end;$$;
insert into auth.users(id) select ('15000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,12)n;
insert into public.profiles(id,name,occupation,summary,skills,searching_skills)
select id,case right(id::text,3) when '001' then 'Viewer' when '002' then 'Target' when '003' then 'Julia Robinson' else 'Person '||right(id::text,3) end,'Designer','Test',array['Marketing'],array[]::text[] from auth.users where id::text like '15000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '15000000-%' and right(id::text,3)<>'007';
update public.profiles set deleted_at=now(),auth_user_id=null,name='Удалённый пользователь',occupation='',summary='',skills=array[]::text[],searching_skills=array[]::text[] where id='15000000-0000-4000-8000-000000000008';
insert into public.profiles(id,profile_kind,name,occupation,summary,skills,searching_skills,disabled_at) values
 ('15000000-0000-4000-8000-000000000013','managed','Disabled mutual','Designer','Test',array['Marketing'],array[]::text[],now()),
 ('15000000-0000-4000-8000-000000000014','managed','Managed mutual','Designer','Test',array['Marketing'],array[]::text[],null);
insert into auth.sessions(id,user_id) values('15000000-1111-4111-8111-000000000001','15000000-0000-4000-8000-000000000001');
insert into public.connections(user_low,user_high)
select viewer,id from (values('15000000-0000-4000-8000-000000000001'::uuid),('15000000-0000-4000-8000-000000000002'::uuid)) v(viewer)
cross join public.profiles where id::text like '15000000-%' and right(id::text,3) in ('003','004','005','006','007','008','013','014');
insert into public.connections(user_low,user_high) values
 ('15000000-0000-4000-8000-000000000002','15000000-0000-4000-8000-000000000011'),
 ('15000000-0000-4000-8000-000000000001','15000000-0000-4000-8000-000000000012');
select pg_temp.assert_true(not has_function_privilege('anon','private.mutual_contacts(uuid)','execute'),'No anonymous graph');
select pg_temp.assert_true(not has_function_privilege('service_role','private.mutual_contacts(uuid)','execute'),'No default service graph API');
select pg_temp.assert_true(to_regprocedure('private.mutual_contacts(uuid,uuid)') is null,'No caller-specified viewer');
select pg_temp.assert_true((select prosecdef and proconfig=array['search_path=""'] from pg_proc where oid='private.mutual_contacts(uuid)'::regprocedure),'Narrow definer fixed path');
set local role anon;
select pg_temp.expect_error($q$select private.mutual_contacts('15000000-0000-4000-8000-000000000002')$q$,'permission denied');
reset role;
set local role authenticated;
set local request.jwt.claim.sub='15000000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"session_id":"15000000-1111-4111-8111-000000000001"}';
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000002')->>'mutual_contact_count'='5','Only active shared member and managed contacts count');
select pg_temp.assert_true(jsonb_array_length(private.mutual_contacts('15000000-0000-4000-8000-000000000002')->'mutual_contacts')=3,'At most three identities');
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000002')->'mutual_contacts'->0->>'name'='Julia Robinson','Deterministic first contact');
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000001')->>'mutual_contact_count'='0','Self has no attribution');
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000011')->>'mutual_contact_count'='0','Never return targets nonshared contacts');
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000007')->>'mutual_contact_count'='0','Pending target hidden');
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000008')->>'mutual_contact_count'='0','Deleted target hidden');
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000013')->>'mutual_contact_count'='0','Disabled target hidden');
select pg_temp.assert_true(public.profile_name_search('Target')->'results'->0->>'mutual_contact_count'='5','Names carry current bounded attribution');
select pg_temp.assert_true((select (x->>'mutual_contact_count')::int=5 from jsonb_array_elements(public.skill_search('Marketing')->'results')x where x->>'id'='15000000-0000-4000-8000-000000000002'),'Skill results carry attribution without audience restriction');
select pg_temp.assert_true((select count(*) from public.connections where user_low='15000000-0000-4000-8000-000000000002')=0,'Original foreign graph RLS unchanged');
set local request.jwt.claims='{}';
select pg_temp.expect_error($q$select private.mutual_contacts('15000000-0000-4000-8000-000000000002')$q$,'session_revoked');
set local request.jwt.claims='{"session_id":"invalid"}';
select pg_temp.expect_error($q$select public.skill_search('missing')$q$,'session_revoked');
set local request.jwt.claims='{"session_id":"15000000-1111-4111-8111-000000000001"}';
set local request.jwt.claim.sub='15000000-0000-4000-8000-000000000002';
select pg_temp.expect_error($q$select private.mutual_contacts('15000000-0000-4000-8000-000000000001')$q$,'session_revoked');
set local request.jwt.claim.sub='15000000-0000-4000-8000-000000000007';
select pg_temp.expect_error($q$select private.mutual_contacts('15000000-0000-4000-8000-000000000002')$q$,'membership_required');
set local request.jwt.claim.sub='15000000-0000-4000-8000-000000000001';
reset role;
delete from public.connections where user_low='15000000-0000-4000-8000-000000000001' and user_high='15000000-0000-4000-8000-000000000003';
set local role authenticated;
select pg_temp.assert_true(private.mutual_contacts('15000000-0000-4000-8000-000000000002')->>'mutual_contact_count'='4','Disconnect immediately removes attribution');
reset role;
update auth.sessions set not_after=now()-interval '1 second' where id='15000000-1111-4111-8111-000000000001';
set local role authenticated;
select pg_temp.expect_error($q$select private.mutual_contacts('15000000-0000-4000-8000-000000000002')$q$,'session_revoked');
select pg_temp.expect_error($q$select public.skill_search('missing')$q$,'session_revoked');
select pg_temp.expect_error($q$select public.profile_name_search('missing')$q$,'session_revoked');
reset role;
delete from auth.sessions where id='15000000-1111-4111-8111-000000000001';
set local role authenticated;
select pg_temp.expect_error($q$select public.profile_name_search('Target')$q$,'session_revoked');
reset role;
rollback;
