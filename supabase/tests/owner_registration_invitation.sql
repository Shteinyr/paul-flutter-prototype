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

insert into auth.users(id) values
 ('77000000-0000-4000-8000-000000000001'),
 ('77000000-0000-4000-8000-000000000002'),
 ('77000000-0000-4000-8000-000000000003');
insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values
 ('77000000-0000-4000-8000-000000000004','managed','Owner assigned QA','','Test',array['Flutter']);
insert into storage.objects(id,bucket_id,name,owner_id)
 select gen_random_uuid(),'avatars',id::text||'/'||repeat('f',64)||'.png',id::text
 from auth.users where id::text like '77000000-%';
create function pg_temp.draft(p_user uuid) returns jsonb language sql as $$
 select jsonb_build_object('name','Owner registration QA','occupation','','summary','Test',
   'skills',array['Flutter'],'searching_skills','[]'::jsonb,
   'avatar_path',p_user::text||'/'||repeat('f',64)||'.png');
$$;

select pg_temp.expect_error($q$select public.issue_owner_registration_invitation(repeat('f',64),null)$q$,'invalid_invitation');
select public.issue_owner_registration_invitation(repeat('a',64),'Owner@example.test',
 array['77000000-0000-4000-8000-000000000004'::uuid]);
select pg_temp.assert_true((select expected_email='owner@example.test' and claimed_at is null
 from private.owner_registration_invitations where token_hash=repeat('a',64)),'Invitation is email-bound and unclaimed');
select pg_temp.assert_true((select jsonb_object_length=2 from (
 select count(*) as jsonb_object_length from jsonb_object_keys(public.check_registration_invitation(repeat('a',64),false))) t),
 'Unauthenticated check exposes only expiry and server time');
select pg_temp.expect_error($q$select public.check_registration_invitation(repeat('a',64),true)$q$,'invalid_invitation');
select pg_temp.expect_error($q$select public.issue_owner_registration_invitation(repeat('b',64),'owner@example.test')$q$,'owner_invitation_pending');
select pg_temp.expect_error($q$select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000001',
 repeat('a',64),false,'{}',null)$q$,'invitation_account_mismatch');
select pg_temp.expect_error($q$select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000002',
 repeat('a',64),false,'{}','other@example.test')$q$,'invitation_account_mismatch');
select pg_temp.expect_error($q$select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000001',
 repeat('a',64),false,'{}','owner@example.test')$q$,'invalid_profile');
select pg_temp.assert_true((select claimed_at is null from private.owner_registration_invitations
 where token_hash=repeat('a',64)) and not exists(select 1 from private.admin_roles where user_id='77000000-0000-4000-8000-000000000001'),
 'Failed registration cannot consume the invitation or grant a role');

select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000001',repeat('a',64),false,
 pg_temp.draft('77000000-0000-4000-8000-000000000001'), 'OWNER@example.test');
select pg_temp.assert_true((select role='owner' from private.admin_roles where user_id='77000000-0000-4000-8000-000000000001')
 and exists(select 1 from private.memberships where user_id='77000000-0000-4000-8000-000000000001'),
 'Registration atomically creates membership and the intended owner role');
select pg_temp.assert_true(jsonb_array_length(public.admin_context('77000000-0000-4000-8000-000000000001')->'profiles')=1,
 'Only the preselected existing managed profile is granted');
select pg_temp.assert_true((select count(*)=0 from private.invited_registrations where invitee_profile_id='77000000-0000-4000-8000-000000000001'),
 'Owner activation does not fabricate referral credit or levels');
select pg_temp.expect_error($q$select public.check_registration_invitation(repeat('a',64),false)$q$,'invalid_invitation');
select pg_temp.expect_error($q$select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000002',
 repeat('a',64),false,'{}','owner@example.test')$q$,'invalid_invitation');
select pg_temp.assert_true((public.redeem_registration_invitation('77000000-0000-4000-8000-000000000001',
 repeat('a',64),false,'{}','owner@example.test')->>'replayed')::boolean,'Lost response retry succeeds for the same account');
select pg_temp.assert_true((select count(*)=1 from private.admin_audit where action='owner_invitation_accepted'
 and actor_user_id='77000000-0000-4000-8000-000000000001'),'Retries produce one audit record');
update private.admin_roles set revoked_at=clock_timestamp() where user_id='77000000-0000-4000-8000-000000000001';
select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000001',repeat('a',64),false,'{}','owner@example.test');
select pg_temp.expect_error($q$select public.admin_context('77000000-0000-4000-8000-000000000001')$q$,'admin_forbidden');

select public.issue_owner_registration_invitation(repeat('b',64),'owner@example.test');
update private.owner_registration_invitations set expires_at=statement_timestamp()-interval '1 second',created_at=statement_timestamp()-interval '2 seconds'
 where token_hash=repeat('b',64);
select pg_temp.expect_error($q$select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000002',
 repeat('b',64),false,'{}','other@example.test')$q$,'invalid_invitation');
select public.issue_owner_registration_invitation(repeat('c',64),'owner@example.test');
update private.owner_registration_invitations set revoked_at=clock_timestamp() where token_hash=repeat('c',64);
select pg_temp.expect_error($q$select public.check_registration_invitation(repeat('c',64),false)$q$,'invalid_invitation');

-- Ordinary invitations still use the old path and never grant privileged roles.
insert into private.invitations(token_hash,created_at,expires_at,max_uses)
 values(repeat('d',64),statement_timestamp(),statement_timestamp()+interval '15 minutes',1);
select public.check_registration_invitation(repeat('d',64),false);
select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000003',repeat('d',64),false,
 pg_temp.draft('77000000-0000-4000-8000-000000000003'),null);
select pg_temp.assert_true(not exists(select 1 from private.admin_roles where user_id='77000000-0000-4000-8000-000000000003'),
 'A normal QR cannot create an administrator');

set local role service_role;
select public.check_registration_invitation(repeat('d',64),false) where false;
select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000003',repeat('d',64),false,'{}',null);
reset role;
set local role authenticated;
select pg_temp.expect_error($q$select public.issue_owner_registration_invitation(repeat('e',64),null)$q$,'permission denied');
select pg_temp.expect_error($q$select public.redeem_registration_invitation('77000000-0000-4000-8000-000000000002',repeat('a',64),false,'{}','owner@example.test')$q$,'permission denied');
select pg_temp.expect_error($q$select * from private.owner_registration_invitations$q$,'permission denied');
reset role;
set local role anon;
select pg_temp.expect_error($q$select public.check_registration_invitation(repeat('a',64),false)$q$,'permission denied');
rollback;
