begin;
create function pg_temp.assert_true(v boolean, description text) returns void language plpgsql as $$
begin if v is distinct from true then raise exception 'Assertion failed: %',description;end if;end;$$;
create function pg_temp.expect_error(statement text, expected text) returns void language plpgsql as $$
begin begin execute statement;exception when others then if position(expected in sqlerrm)>0 then return;end if;raise;end;
raise exception 'Expected %',expected;end;$$;
insert into auth.users(id) values('13300000-0000-4000-8000-000000000001');
select private.save_profile('13300000-0000-4000-8000-000000000001',
  '{"name":"Original","occupation":"Designer","summary":"Original summary","skills":["Design"],"searching_skills":[],"avatar_path":null}');
insert into private.memberships(user_id) values('13300000-0000-4000-8000-000000000001');
create temp table snapshot as select jsonb_build_object('name',name,'occupation',occupation,'summary',summary,
 'skills',skills,'searching_skills',searching_skills,'avatar_path',avatar_path) as base from public.profiles
 where id='13300000-0000-4000-8000-000000000001';
grant select on snapshot to service_role;
set local role service_role;
-- Two sequential real clients started from the same snapshot.
select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000001',
 (select base from snapshot),'{"summary":"Device B summary"}');
select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000002',
 (select base from snapshot),'{"name":"Device A name"}');
select pg_temp.assert_true((select name='Device A name' and summary='Device B summary' from public.profiles where id='13300000-0000-4000-8000-000000000001'),'Disjoint stale writes merge');
select pg_temp.expect_error($q$select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000003',
 (select base from snapshot),'{"summary":"Stale overwrite"}')$q$,'profile_conflict');
-- Deliberate ABA, then replay an earlier successful operation after a lost response.
reset role;
update public.profiles set summary='Original summary' where id='13300000-0000-4000-8000-000000000001';
set local role service_role;
select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000001',
 (select base from snapshot),'{"summary":"Device B summary"}');
select pg_temp.assert_true((select summary='Original summary' from public.profiles where id='13300000-0000-4000-8000-000000000001'),'ABA replay does not reapply an old patch');
select pg_temp.expect_error($q$select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000001',
 (select base from snapshot),'{"summary":"Altered receipt"}')$q$,'invalid_profile');
select pg_temp.expect_error($q$select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000004',
 (select base from snapshot),'{"skills":["1","2","3","4","5","6"]}')$q$,'offering_limit_reached');
select pg_temp.expect_error($q$select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000004',
 (select base from snapshot),'{"avatar_path":"other-user/private.png"}')$q$,'invalid_profile');
reset role;
select pg_temp.assert_true(not has_function_privilege('authenticated','public.merge_member_profile(uuid,uuid,jsonb,jsonb)','execute'),'Member cannot impersonate actor through RPC');
select pg_temp.assert_true(not has_table_privilege('authenticated','private.profile_write_receipts','select'),'Receipts private');
-- Removal follows the existing lifecycle; replacement/retired guards still run.
insert into storage.objects values(gen_random_uuid(),'avatars','13300000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png','13300000-0000-4000-8000-000000000001');
set local role service_role;
select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000005',
 (select base from snapshot),jsonb_build_object('avatar_path','13300000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png'));
select pg_temp.assert_true(exists(select 1 from private.avatar_uploads where path='13300000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png'),'Reference still goes through lifecycle73 guard');
select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000006',
 (select base||jsonb_build_object('avatar_path','13300000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png') from snapshot),'{"avatar_path":null}');
select pg_temp.assert_true((select avatar_path is null from public.profiles where id='13300000-0000-4000-8000-000000000001'),'Removal persists without upload');
reset role;
insert into auth.sessions(id,user_id) values('13300000-0000-4000-8000-000000000099','13300000-0000-4000-8000-000000000001');
set local role service_role;
select public.member_delete_account('13300000-0000-4000-8000-000000000001','13300000-0000-4000-8000-000000000099',
 '13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000099',repeat('a',64));
select pg_temp.expect_error($q$select public.merge_member_profile('13300000-0000-4000-8000-000000000001','13310000-0000-4000-8000-000000000001',
 (select base from snapshot),'{"summary":"Device B summary"}')$q$,'account_deleted');
reset role;
select pg_temp.assert_true(not exists(select 1 from private.profile_write_receipts where actor_id='13300000-0000-4000-8000-000000000001'),'Deletion removes all receipts');
rollback;
