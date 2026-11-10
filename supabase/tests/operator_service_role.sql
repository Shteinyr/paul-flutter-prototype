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
insert into auth.users(id) values('44600000-0000-4000-8000-000000000001'),('44600000-0000-4000-8000-000000000002');
select private.save_profile(id,jsonb_build_object('name','Operator service QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '44600000-%';
insert into private.memberships(user_id) values('44600000-0000-4000-8000-000000000001'),('44600000-0000-4000-8000-000000000002');
insert into private.admin_roles(user_id,role) values('44600000-0000-4000-8000-000000000001','admin');
insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values('44600000-0000-4000-8000-000000000003','managed','Managed service QA','','Test',array['Design']);
insert into private.managed_profile_grants(user_id,profile_id,can_manage,can_reply) values('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003',true,true);
insert into public.connections(user_low,user_high) values('44600000-0000-4000-8000-000000000002','44600000-0000-4000-8000-000000000003');
create temp table service_operator_thread(id uuid);
grant all on service_operator_thread to service_role;
set local role service_role;
select pg_temp.assert_true(not has_table_privilege('service_role','auth.users','select'),'Operator service uses the actual Auth privilege boundary');
insert into service_operator_thread select (public.chat_open('44600000-0000-4000-8000-000000000002','44600000-0000-4000-8000-000000000003')->>'id')::uuid;
select public.chat_send('44600000-0000-4000-8000-000000000002',(select id from service_operator_thread),'44600000-0000-4000-8000-000000000004','Service incoming');
select pg_temp.assert_true(jsonb_array_length(public.operator_inbox('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003')->'conversations')=1,'Service inbox succeeds');
select public.operator_send('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003',(select id from service_operator_thread),'44600000-0000-4000-8000-000000000005','Service manual reply');
select pg_temp.assert_true((public.operator_send('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003',(select id from service_operator_thread),'44600000-0000-4000-8000-000000000005','Service manual reply')->>'replayed')::boolean,'Service reply retry succeeds');
select pg_temp.assert_true(jsonb_array_length(public.operator_history('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003',(select id from service_operator_thread))->'messages')=2,'Service history succeeds');
select public.operator_read('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003',(select id from service_operator_thread),2);
select pg_temp.assert_true((public.operator_inbox('44600000-0000-4000-8000-000000000001','44600000-0000-4000-8000-000000000003')->'conversations'->0->>'unread_count')::int=0,'Service read uses intended managed member');
select pg_temp.expect_error($q$select public.operator_inbox('44600000-0000-4000-8000-000000000002','44600000-0000-4000-8000-000000000003')$q$,'admin_forbidden');
select pg_temp.assert_true(not has_table_privilege('service_role','auth.users','select'),'Operator operations introduce no Auth read privilege');
reset role;
rollback;
