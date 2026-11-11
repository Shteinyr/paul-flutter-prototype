begin;
create function pg_temp.assert_true(value boolean,description text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'Assertion failed: %',description; end if; end;
$$;
create function pg_temp.expect_error(statement text,expected text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then if position(expected in sqlerrm)>0 then return; end if; raise; end;
  raise exception 'Expected failure %',expected;
end;
$$;
-- Only this isolated module suite replaces the later integration's push hooks.
create temp table community_test_hooks(kind text,request uuid);
grant all on community_test_hooks to service_role;
create or replace function private.enqueue_community_notifications(p_request uuid) returns void
language sql set search_path='' as $$insert into pg_temp.community_test_hooks values('enqueue',p_request);$$;
create or replace function private.cancel_community_notifications(p_request uuid) returns void
language sql set search_path='' as $$insert into pg_temp.community_test_hooks values('cancel',p_request);$$;
insert into auth.users(id) select ('47000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,12)n;
select private.save_profile(id,jsonb_build_object('name','Community SQL QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb))
  from auth.users where id::text like '47000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '47000000-%';
insert into auth.sessions(id,user_id) values
  ('47100000-0000-4000-8000-000000000001','47000000-0000-4000-8000-000000000001'),
  ('47100000-0000-4000-8000-000000000002','47000000-0000-4000-8000-000000000002');
select pg_temp.assert_true(not has_table_privilege('authenticated','public.community_requests','SELECT'),'Browser cannot bypass guarded feed');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.community_create(uuid,uuid,uuid,text,text)','EXECUTE'),'Browser cannot invoke service RPC');
set local role service_role;
select pg_temp.expect_error($q$select public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47200000-0000-4000-8000-000000000001','Design','Help with a product')$q$,'community_locked');
reset role;
insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
  select id,'47000000-0000-4000-8000-000000000001',clock_timestamp() from auth.users
  where id::text like '47000000-%' and id>'47000000-0000-4000-8000-000000000002' and id<'47000000-0000-4000-8000-000000000012';
set local role service_role;
select pg_temp.expect_error($q$select public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47200000-0000-4000-8000-000000000001','Design','Help with a product')$q$,'community_locked');
reset role;
insert into private.invited_registrations values('47000000-0000-4000-8000-000000000012','47000000-0000-4000-8000-000000000001',clock_timestamp());
set local role service_role;
create temp table first_result as select public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47200000-0000-4000-8000-000000000001','  Product   Design ','Help with a product') as data;
select pg_temp.assert_true((select data->>'state'='active' from first_result),'Ten registrations permit publishing');
select pg_temp.assert_true((select count(*)=1 from public.community_requests),'One request');
select pg_temp.assert_true((select skill='Product Design' and expires_at-created_at=interval '30 days' from public.community_requests),'Normalized skill and exact thirty-day lifetime');
select pg_temp.assert_true((select count(*)=1 from community_test_hooks where kind='enqueue'),'One transactional enqueue');
select pg_temp.assert_true((public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47200000-0000-4000-8000-000000000001','Product Design','Help with a product')->>'replayed')::boolean,'Lost acknowledgement reuses receipt');
select pg_temp.assert_true((select count(*)=1 from community_test_hooks where kind='enqueue'),'Replay does not enqueue again');
select pg_temp.expect_error($q$select public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47200000-0000-4000-8000-000000000001','Different','Different text')$q$,'operation_id_conflict');
select pg_temp.assert_true(jsonb_array_length(public.community_feed('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002')->'requests')=1,'Zero-level member reads global Hiring');
select pg_temp.assert_true(not (public.community_feed('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002')->'requests'->0->>'is_author')::boolean,'Ownership is server-derived');
select pg_temp.expect_error($q$select public.community_close('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002',gen_random_uuid(),(select (data->>'request_id')::uuid from first_result))$q$,'community_forbidden');
select public.community_close('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47300000-0000-4000-8000-000000000001',(select (data->>'request_id')::uuid from first_result));
select pg_temp.assert_true((select count(*)=0 from public.community_requests),'Close physically removes request text');
select pg_temp.assert_true((select count(*)=1 from community_test_hooks where kind='cancel'),'Close cancels pending delivery');
select public.community_close('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47300000-0000-4000-8000-000000000001',(select (data->>'request_id')::uuid from first_result));
select pg_temp.assert_true((select count(*)=1 from community_test_hooks where kind='cancel'),'Close receipt is idempotent');
select pg_temp.assert_true(public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001','47200000-0000-4000-8000-000000000001','Product Design','Help with a product')->>'state'='unavailable','Old create cannot resurrect a closed request');
select pg_temp.assert_true(public.community_get('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002',(select (data->>'request_id')::uuid from first_result))->'request'='null'::jsonb,'Old notification displays unavailable');
-- No active-request quota. Test tied timestamps and a stable unique cursor.
select public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001',gen_random_uuid(),'Design','Request '||n) from generate_series(1,4)n;
update public.community_requests set created_at='2026-11-11T00:00:00Z',expires_at=clock_timestamp()+interval '1 day';
create temp table first_page as select public.community_feed('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002',null,2) as data;
create temp table next_page as select public.community_feed('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002',(select data->'next_cursor' from first_page),2) as data;
select pg_temp.assert_true((select jsonb_array_length(data->'requests')=2 from next_page),'Tied dates page correctly');
select pg_temp.assert_true((select count(distinct item->>'id')=4 from (select jsonb_array_elements(data->'requests') item from first_page union all select jsonb_array_elements(data->'requests') from next_page) all_rows),'Pages contain no duplicate requests');
update public.community_requests set created_at=clock_timestamp()-interval '31 days',expires_at=clock_timestamp()-interval '1 second';
select pg_temp.assert_true(jsonb_array_length(public.community_feed('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002')->'requests')=0,'Expiry hides request before the sweeper');
select pg_temp.assert_true(public.community_expire(2)=2,'Expiry sweeper is bounded');
select pg_temp.assert_true(public.community_expire(200)=2,'Next expiry pass finishes removal');
select pg_temp.assert_true((select count(*)=0 from public.community_requests),'Expired records physically removed');
select public.community_create('47000000-0000-4000-8000-000000000001','47100000-0000-4000-8000-000000000001',gen_random_uuid(),'Design','Account deletion request');
select private.community_remove_for_author('47000000-0000-4000-8000-000000000001');
select pg_temp.assert_true((select count(*)=0 from public.community_requests),'Account cleanup removes authored requests');
reset role;
delete from auth.sessions where id='47100000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.expect_error($q$select public.community_feed('47000000-0000-4000-8000-000000000002','47100000-0000-4000-8000-000000000002')$q$,'session_revoked');
rollback;
