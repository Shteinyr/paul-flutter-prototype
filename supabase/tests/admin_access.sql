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
insert into auth.users(id) values ('42000000-0000-4000-8000-000000000001'),
 ('42000000-0000-4000-8000-000000000002'),('42000000-0000-4000-8000-000000000003');
select private.save_profile(id,jsonb_build_object('name','Admin Access QA','occupation','','summary','Test',
 'skills',array['Flutter'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '42000000-%';
insert into private.memberships(user_id) values ('42000000-0000-4000-8000-000000000001'),('42000000-0000-4000-8000-000000000002');
select pg_temp.assert_true((select bool_and(id=auth_user_id and profile_kind='member') from public.profiles where id::text like '42000000-%'),'Legacy save callers retain member identity');
select pg_temp.expect_error($q$select public.admin_context('42000000-0000-4000-8000-000000000002')$q$,'admin_forbidden');
insert into private.admin_roles(user_id,role) values ('42000000-0000-4000-8000-000000000001','owner'),('42000000-0000-4000-8000-000000000003','admin');
select pg_temp.expect_error($q$select public.admin_context('42000000-0000-4000-8000-000000000003')$q$,'admin_forbidden');
insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values
 ('42000000-0000-4000-8000-000000000004','managed','Managed QA','','Test',array['Flutter']),
 ('42000000-0000-4000-8000-000000000005','managed','Foreign QA','','Test',array['Flutter']);
insert into private.managed_profile_grants(user_id,profile_id,can_manage) values
 ('42000000-0000-4000-8000-000000000001','42000000-0000-4000-8000-000000000004',true);
select pg_temp.assert_true(jsonb_array_length(public.admin_context('42000000-0000-4000-8000-000000000001')->'profiles')=1,'Only assigned managed profiles appear');
select private.require_managed_profile('42000000-0000-4000-8000-000000000001','42000000-0000-4000-8000-000000000004');
select pg_temp.expect_error($q$select private.require_managed_profile('42000000-0000-4000-8000-000000000001','42000000-0000-4000-8000-000000000005')$q$,'managed_profile_forbidden');
select pg_temp.expect_error($q$select private.require_managed_profile('42000000-0000-4000-8000-000000000001','42000000-0000-4000-8000-000000000004',true)$q$,'managed_profile_forbidden');
update private.managed_profile_grants set revoked_at=clock_timestamp();
select pg_temp.assert_true(jsonb_array_length(public.admin_context('42000000-0000-4000-8000-000000000001')->'profiles')=0,'Grant revocation is immediate');
select pg_temp.expect_error($q$select private.require_managed_profile('42000000-0000-4000-8000-000000000001','42000000-0000-4000-8000-000000000004')$q$,'managed_profile_forbidden');
update private.admin_roles set revoked_at=clock_timestamp() where user_id='42000000-0000-4000-8000-000000000001';
select pg_temp.expect_error($q$select public.admin_context('42000000-0000-4000-8000-000000000001')$q$,'admin_forbidden');
select pg_temp.expect_error($q$delete from auth.users where id='42000000-0000-4000-8000-000000000002'$q$,'profiles_auth_user_id_fkey');
set local role authenticated;
select set_config('request.jwt.claim.sub','42000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true((select count(*)=1 from public.profiles where id::text like '42000000-%'),'Even admins have unchanged self/direct profile RLS');
select pg_temp.expect_error($q$select public.admin_context('42000000-0000-4000-8000-000000000001')$q$,'permission denied');
select pg_temp.expect_error($q$insert into private.admin_roles(user_id,role) values(auth.uid(),'owner')$q$,'permission denied');
select pg_temp.expect_error($q$update private.managed_profile_grants set can_reply=true$q$,'permission denied');
select pg_temp.expect_error($q$update public.profiles set profile_kind='managed',auth_user_id=null where id=auth.uid()$q$,'permission denied');
rollback;
