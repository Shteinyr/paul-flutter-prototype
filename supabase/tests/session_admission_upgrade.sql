-- ONLY after upgrade_setup + both mobile migrations in the same disposable DB.
begin;
create function pg_temp.assert_true(ok boolean, description text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',description; end if; end;$$;
create function pg_temp.reject(statement text, expected text) returns void language plpgsql as $$
begin
 begin execute statement; exception when others then
   if sqlerrm=expected then return; end if; raise;
 end;
 raise exception 'Expected rejection: %',expected;
end;$$;
select pg_temp.assert_true((select count(*)=4 from private.session_admissions where legacy_snapshot_at is not null),'real migration captures four existing active member sessions');
select pg_temp.assert_true(not exists(select 1 from private.session_admissions where session_id='92100000-0000-4000-8000-000000000005'),'snapshot excludes expired Auth session');
select pg_temp.assert_true((public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('a7',32),false,'{"name":"Must not overwrite"}',null)->>'replayed')::boolean,'ordinary legacy lost ACK survives expiry');
select pg_temp.assert_true((public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('b7',32),true,'{}',null)->>'replayed')::boolean,'manual legacy receipt is also user bound');
select pg_temp.assert_true((public.redeem_session_invitation('92000000-0000-4000-8000-000000000003','92100000-0000-4000-8000-000000000003',repeat('e7',32),false,'{}',null)->>'replayed')::boolean,'owner claimed history acknowledges without reactivating role');
select pg_temp.assert_true(not exists(select 1 from private.admin_roles where user_id='92000000-0000-4000-8000-000000000003' and revoked_at is null),'legacy owner replay cannot restore revoked role');
select pg_temp.assert_true((select summary='Preserve ordinary profile' from public.profiles where id='92000000-0000-4000-8000-000000000002'),'legacy replay does not overwrite profile');
select pg_temp.assert_true((select count(*)=1 from private.invited_registrations where invitee_profile_id='92000000-0000-4000-8000-000000000002'),'legacy replay does not duplicate referral');
select pg_temp.assert_true(not exists(select 1 from public.connections where user_low='92000000-0000-4000-8000-000000000001' and user_high='92000000-0000-4000-8000-000000000002'),'legacy replay does not restore disconnected pair');
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000004','92100000-0000-4000-8000-000000000004',repeat('a7',32),false,'{}',null)$q$,'invalid_invitation');
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('c7',32),false,'{}',null)$q$,'invalid_invitation');
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000004','92100000-0000-4000-8000-000000000004',repeat('e7',32),false,'{}',null)$q$,'invalid_invitation');
insert into auth.sessions(id,user_id) values('92100000-0000-4000-8000-000000000006','92000000-0000-4000-8000-000000000002');
insert into auth.sessions(id,user_id) values('92100000-0000-4000-8000-000000000007','92000000-0000-4000-8000-000000000003');
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000006',repeat('a7',32),false,'{}',null)$q$,'invalid_invitation');
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000003','92100000-0000-4000-8000-000000000007',repeat('e7',32),false,'{}',null)$q$,'invalid_invitation');
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000005',repeat('a7',32),false,'{}',null)$q$,'session_revoked');
select public.issue_invitation('92000000-0000-4000-8000-000000000001',repeat('f7',32),repeat('97',32));
select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000006',repeat('f7',32),false,'{}',null);
update private.invitations set created_at=statement_timestamp()-interval '16 minutes',expires_at=statement_timestamp()-interval '1 minute' where token_hash=repeat('f7',32);
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('f7',32),false,'{}',null)$q$,'invalid_invitation');
-- Current admission may change its source without losing the immutable snapshot
-- boundary. History created after that boundary is never a legacy receipt.
select public.issue_invitation('92000000-0000-4000-8000-000000000001',repeat('17',32),repeat('27',32));
select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('17',32),false,'{}',null);
select pg_temp.assert_true((public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('a7',32),false,'{}',null)->>'replayed')::boolean,'snapshot proof persists after a later admission');
update private.session_admissions set revoked_at=clock_timestamp() where session_id='92100000-0000-4000-8000-000000000002';
select pg_temp.reject($q$select public.redeem_session_invitation('92000000-0000-4000-8000-000000000002','92100000-0000-4000-8000-000000000002',repeat('a7',32),false,'{}',null)$q$,'invalid_invitation');

-- Exercise the real Storage policies, not just the private helper.
insert into auth.users(id) values('93000000-0000-4000-8000-000000000001');
insert into auth.sessions(id,user_id) values('93100000-0000-4000-8000-000000000001','93000000-0000-4000-8000-000000000001');
select public.issue_invitation('92000000-0000-4000-8000-000000000001',repeat('37',32),repeat('47',32));
select public.prepare_registration_session('93000000-0000-4000-8000-000000000001','93100000-0000-4000-8000-000000000001',repeat('37',32),false,null);
select set_config('request.jwt.claim.sub','93000000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"session_id":"93100000-0000-4000-8000-000000000001"}',true);
set local role authenticated;
select pg_temp.assert_true(private.avatar_owner_access(),'active ordinary permit allows its owner');
insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','93000000-0000-4000-8000-000000000001/'||repeat('a7',32)||'.png','93000000-0000-4000-8000-000000000001');
select pg_temp.assert_true((select count(*)=1 from storage.objects),'valid permit can read its own uploaded photo');
reset role;
update private.invitations set revoked_at=clock_timestamp() where token_hash=repeat('37',32);
set local role authenticated;
select pg_temp.assert_true(not private.avatar_owner_access(),'ordinary revocation invalidates existing permit');
select pg_temp.assert_true((select count(*)=0 from storage.objects),'Storage hides previously uploaded photo after revoke');
select pg_temp.reject($q$insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','93000000-0000-4000-8000-000000000001/'||repeat('b7',32)||'.png','93000000-0000-4000-8000-000000000001')$q$,'new row violates row-level security policy for table "objects"');
reset role;
update private.invitations set revoked_at=null,max_uses=1,uses=1 where token_hash=repeat('37',32);
select pg_temp.assert_true(not private.avatar_owner_access(),'exhausted invitation invalidates outstanding permit');
update private.invitations set max_uses=null,uses=0,created_at=statement_timestamp()-interval '16 minutes',expires_at=statement_timestamp()-interval '1 minute' where token_hash=repeat('37',32);
select pg_temp.assert_true(not private.avatar_owner_access(),'ordinary invite expiry invalidates permit even if permit TTL remains');
update private.invitations set created_at=statement_timestamp(),expires_at=statement_timestamp()+interval '15 minutes' where token_hash=repeat('37',32);
delete from private.memberships where user_id='92000000-0000-4000-8000-000000000001';
select pg_temp.assert_true(not private.avatar_owner_access(),'issuer membership loss invalidates permit');
insert into private.memberships(user_id) values('92000000-0000-4000-8000-000000000001');
select pg_temp.assert_true(private.avatar_owner_access(),'restored valid ordinary invitation is recognized');

-- Switching the permit to an owner invitation must retain that namespace and
-- canonical recipient. A 7-day owner invite still grants at most 15 minutes.
select public.issue_owner_registration_invitation(repeat('57',32),'new-owner@example.invalid');
select public.prepare_registration_session('93000000-0000-4000-8000-000000000001','93100000-0000-4000-8000-000000000001',repeat('57',32),false,'new-owner@example.invalid');
select pg_temp.assert_true(private.avatar_owner_access(),'active unclaimed owner invite permits upload');
select pg_temp.assert_true((select source='owner_invitation' and owner_email='new-owner@example.invalid'
 and expires_at<=clock_timestamp()+interval '15 minutes' from private.registration_upload_permits where user_id='93000000-0000-4000-8000-000000000001'),'permit stores owner invitation and caps lifetime');
update private.owner_registration_invitations set revoked_at=clock_timestamp() where token_hash=repeat('57',32);
set local role authenticated;
select pg_temp.assert_true((select count(*)=0 from storage.objects),'owner revocation also hides own stored photo');
select pg_temp.reject($q$insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','93000000-0000-4000-8000-000000000001/'||repeat('c7',32)||'.png','93000000-0000-4000-8000-000000000001')$q$,'new row violates row-level security policy for table "objects"');
reset role;
update private.owner_registration_invitations set revoked_at=null,claimed_at=clock_timestamp(),claimed_by='92000000-0000-4000-8000-000000000004' where token_hash=repeat('57',32);
select pg_temp.assert_true(not private.avatar_owner_access(),'claim by another user invalidates owner permit');
update private.owner_registration_invitations set claimed_at=null,claimed_by=null,expected_email='different-owner@example.invalid' where token_hash=repeat('57',32);
select pg_temp.assert_true(not private.avatar_owner_access(),'recipient change invalidates old owner permit');
update private.owner_registration_invitations set expected_email='new-owner@example.invalid',created_at=statement_timestamp()-interval '8 days',expires_at=statement_timestamp()-interval '1 day' where token_hash=repeat('57',32);
select pg_temp.assert_true(not private.avatar_owner_access(),'owner expiry invalidates permit before permit TTL');
select pg_temp.assert_true(not has_function_privilege('authenticated','private.registration_upload_permit_valid(uuid,uuid)','execute'),'permit details remain service only');
select 'PASS upgrade receipts and invite-bound Storage permits: ordinary/owner/revoke/expiry/exhaustion/recipient';
rollback;
