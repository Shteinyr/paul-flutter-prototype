-- Only the disposable local database. All fixtures roll back.
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
insert into auth.users(id) values ('91500000-0000-4000-8000-000000000001'),('91500000-0000-4000-8000-000000000002');
insert into auth.sessions(id,user_id) values
 ('91510000-0000-4000-8000-000000000001','91500000-0000-4000-8000-000000000001'),
 ('91510000-0000-4000-8000-000000000002','91500000-0000-4000-8000-000000000002'),
 ('91510000-0000-4000-8000-000000000003','91500000-0000-4000-8000-000000000002');
select private.save_profile('91500000-0000-4000-8000-000000000001','{"name":"Inviter","occupation":"","summary":"Local test","skills":["Design"],"searching_skills":[]}');
insert into private.memberships(user_id) values('91500000-0000-4000-8000-000000000001');
insert into private.session_admissions(user_id,session_id,source) values('91500000-0000-4000-8000-000000000001','91510000-0000-4000-8000-000000000001','existing_session');
select public.issue_invitation('91500000-0000-4000-8000-000000000001',repeat('a',64),repeat('b',64));
select pg_temp.reject($q$select private.require_member_session('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000002')$q$,'membership_required');
select set_config('request.jwt.claim.sub','91500000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"session_id":"91510000-0000-4000-8000-000000000002"}',true);
select pg_temp.assert_true(not private.avatar_owner_access(),'raw auth alone cannot upload/read own photos');
select public.prepare_registration_session('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000002',repeat('a',64),false,null);
select pg_temp.assert_true(private.avatar_owner_access(),'fresh invitation permits only registration avatar');
select pg_temp.assert_true(not private.is_member(),'upload permit is not membership admission');
insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','91500000-0000-4000-8000-000000000002/'||repeat('c',64)||'.png','91500000-0000-4000-8000-000000000002');
select public.redeem_session_invitation('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000002',repeat('a',64),false,
 jsonb_build_object('name','New member','occupation','','summary','Original profile','skills',array['Design'],'searching_skills','[]'::jsonb,'avatar_path','91500000-0000-4000-8000-000000000002/'||repeat('c',64)||'.png'),null);
select pg_temp.assert_true(private.is_member(),'admitted session can use RLS member predicates');
select pg_temp.assert_true((select count(*)=1 from private.invited_registrations where invitee_profile_id='91500000-0000-4000-8000-000000000002'),'one referral');
select pg_temp.assert_true(not exists(select 1 from private.registration_upload_permits where session_id='91510000-0000-4000-8000-000000000002'),'upload permit removed after finalization');
-- Expire the code after successful completion, retaining the same session.
update private.invitations set created_at=statement_timestamp()-interval '16 minutes',expires_at=statement_timestamp()-interval '1 minute' where token_hash=repeat('a',64);
select pg_temp.assert_true((public.redeem_session_invitation('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000002',repeat('a',64),false,'{}',null)->>'replayed')::boolean,'lost ACK in same session survives invite TTL');
select pg_temp.assert_true(private.member_session_admitted('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000002'),'refresh of admitted session remains allowed');
select pg_temp.reject($q$select public.redeem_session_invitation('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000003',repeat('a',64),false,'{}',null)$q$,'invalid_invitation');
select pg_temp.reject($q$select private.require_member_session('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000003')$q$,'invitation_required');
select set_config('request.jwt.claims','{"session_id":"91510000-0000-4000-8000-000000000003"}',true);
select pg_temp.assert_true(not private.is_member() and not private.avatar_owner_access(),'same user/new session has no member or photo access');
select pg_temp.assert_true(private.push_route('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000003',gen_random_uuid()) is null,'push rejects unadmitted session');
select public.issue_invitation('91500000-0000-4000-8000-000000000001',repeat('d',64),repeat('e',64));
select public.redeem_session_invitation('91500000-0000-4000-8000-000000000002','91510000-0000-4000-8000-000000000003',repeat('d',64),false,'{"name":"Must not overwrite"}',null);
select pg_temp.assert_true(private.is_member(),'existing member may enter new session with fresh code');
select pg_temp.assert_true((select summary='Original profile' from public.profiles where id='91500000-0000-4000-8000-000000000002'),'reentry retains profile');
select pg_temp.assert_true((select count(*)=1 from private.invited_registrations where invitee_profile_id='91500000-0000-4000-8000-000000000002'),'reentry does not increase referral');
select pg_temp.reject($q$select public.redeem_session_invitation('91500000-0000-4000-8000-000000000001','91510000-0000-4000-8000-000000000003',repeat('d',64),false,'{}',null)$q$,'session_revoked');
-- Browser roles cannot manufacture admissions or call service-only finalization.
select pg_temp.assert_true(not has_table_privilege('authenticated','private.session_admissions','INSERT'),'client cannot grant admission');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.redeem_session_invitation(uuid,uuid,text,boolean,jsonb,text)','EXECUTE'),'service-only admission RPC');
delete from auth.sessions where id='91510000-0000-4000-8000-000000000003';
select pg_temp.assert_true(not private.is_member(),'revoked Auth session invalidates admission immediately');
select 'PASS session admission: registration, photos, RLS, TTL, retry, fresh login, referrals, identity, revocation';
rollback;
