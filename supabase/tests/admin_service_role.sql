-- The hosted Edge database role has no SELECT privilege on auth.users.
-- Exercise the actual service-only entry points with that same privilege set.
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
insert into auth.users(id) values('43600000-0000-4000-8000-000000000001'),('43600000-0000-4000-8000-000000000002'),('43600000-0000-4000-8000-000000000003');
select private.save_profile(id,jsonb_build_object('name','Service role QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '43600000-%' and id::text not like '%003';
insert into private.memberships(user_id) values('43600000-0000-4000-8000-000000000001'),('43600000-0000-4000-8000-000000000002');
insert into private.admin_roles(user_id,role) values('43600000-0000-4000-8000-000000000001','admin');
create temp table service_fixture(profile_id uuid,original_version timestamptz);
create temp table service_draft as select jsonb_build_object('name','Managed service QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb,'avatar_path',null) data;
grant all on service_fixture,service_draft to service_role;
set local role service_role;
select pg_temp.assert_true(not has_table_privilege('service_role','auth.users','select'),'Actual service role cannot read Auth user rows');
insert into service_fixture(profile_id) select public.admin_prepare_create('43600000-0000-4000-8000-000000000001','43600000-0000-4000-8000-000000000004');
select public.admin_authorize_save('43600000-0000-4000-8000-000000000001',(select profile_id from service_fixture),true,'43600000-0000-4000-8000-000000000004');
select pg_temp.expect_error($q$select public.admin_authorize_save('43600000-0000-4000-8000-000000000001','43600000-0000-4000-8000-000000000003',true,'43600000-0000-4000-8000-000000000004')$q$,'managed_profile_forbidden');
select public.admin_save_profile('43600000-0000-4000-8000-000000000001',(select profile_id from service_fixture),true,'43600000-0000-4000-8000-000000000004',(select data from service_draft));
select pg_temp.assert_true((public.admin_save_profile('43600000-0000-4000-8000-000000000001',(select profile_id from service_fixture),true,'43600000-0000-4000-8000-000000000004',(select data from service_draft))->>'replayed')::boolean,'Service create retry is idempotent');
select pg_temp.assert_true(jsonb_array_length(public.admin_context('43600000-0000-4000-8000-000000000001')->'profiles')=1,'Service context returns assigned managed');
update service_fixture set original_version=(select updated_at from public.profiles where id=profile_id);
update service_draft set data=data || '{"name":"Managed service edited QA"}'::jsonb;
select public.admin_save_profile('43600000-0000-4000-8000-000000000001',(select profile_id from service_fixture),false,'43600000-0000-4000-8000-000000000005',(select data from service_draft),(select original_version from service_fixture));
select public.admin_set_profile_enabled('43600000-0000-4000-8000-000000000001',(select profile_id from service_fixture),false,'43600000-0000-4000-8000-000000000006',(select updated_at from public.profiles where id=(select profile_id from service_fixture)));
select pg_temp.assert_true((select disabled_at is not null from public.profiles where id=(select profile_id from service_fixture)),'Service disable succeeds');
select public.admin_set_profile_enabled('43600000-0000-4000-8000-000000000001',(select profile_id from service_fixture),true,'43600000-0000-4000-8000-000000000007',(select updated_at from public.profiles where id=(select profile_id from service_fixture)));
select pg_temp.expect_error($q$select public.admin_prepare_create('43600000-0000-4000-8000-000000000002','43600000-0000-4000-8000-000000000008')$q$,'admin_forbidden');
select pg_temp.assert_true(not has_table_privilege('service_role','auth.users','select'),'No broad Auth grant introduced');
reset role;
set local role authenticated;
select pg_temp.expect_error($q$select public.admin_prepare_create('43600000-0000-4000-8000-000000000001',gen_random_uuid())$q$,'permission denied');
reset role;
rollback;
