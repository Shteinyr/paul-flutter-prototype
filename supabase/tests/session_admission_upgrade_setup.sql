-- ONLY before the admission migration in an empty disposable PostgreSQL.
-- Real legacy RPCs create the history that the migration must preserve.
begin;
insert into auth.users(id) select ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,4)n;
insert into auth.sessions(id,user_id) select
 ('92100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,4)n;
insert into auth.sessions(id,user_id,not_after) values
 ('92100000-0000-4000-8000-000000000005','92000000-0000-4000-8000-000000000002',clock_timestamp()-interval '1 minute');
select private.save_profile(id,jsonb_build_object('name','Legacy participant','occupation','','summary','Preserve legacy profile',
 'skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users
 where id in('92000000-0000-4000-8000-000000000001','92000000-0000-4000-8000-000000000004');
insert into private.memberships(user_id) values
 ('92000000-0000-4000-8000-000000000001'),('92000000-0000-4000-8000-000000000004');
insert into storage.objects(id,bucket_id,name,owner_id)
 select gen_random_uuid(),'avatars',id::text||'/'||repeat('a7',32)||'.png',id::text from auth.users
 where id in('92000000-0000-4000-8000-000000000002','92000000-0000-4000-8000-000000000003');
select public.issue_invitation('92000000-0000-4000-8000-000000000001',repeat('a7',32),repeat('b7',32));
select public.redeem_registration_invitation('92000000-0000-4000-8000-000000000002',repeat('a7',32),false,
 jsonb_build_object('name','Legacy member','occupation','','summary','Preserve ordinary profile','skills',array['Design'],
 'searching_skills','[]'::jsonb,'avatar_path','92000000-0000-4000-8000-000000000002/'||repeat('a7',32)||'.png'),null);
select public.issue_invitation('92000000-0000-4000-8000-000000000001',repeat('c7',32),repeat('d7',32));
select public.issue_owner_registration_invitation(repeat('e7',32),'legacy-owner@example.invalid');
select public.redeem_registration_invitation('92000000-0000-4000-8000-000000000003',repeat('e7',32),false,
 jsonb_build_object('name','Legacy owner','occupation','','summary','Preserve owner profile','skills',array['Design'],
 'searching_skills','[]'::jsonb,'avatar_path','92000000-0000-4000-8000-000000000003/'||repeat('a7',32)||'.png'),
 'legacy-owner@example.invalid');
-- Simulate cleanup/expiry after the server committed but before the client got
-- its acknowledgement. Replay must not reconnect users or restore owner roles.
delete from public.connections where user_low='92000000-0000-4000-8000-000000000001'
 and user_high='92000000-0000-4000-8000-000000000002';
update private.admin_roles set revoked_at=clock_timestamp() where user_id='92000000-0000-4000-8000-000000000003';
-- Assign both timestamp columns from one statement timestamp (exact TTL check).
update private.invitations set created_at=statement_timestamp()-interval '16 minutes',
 expires_at=statement_timestamp()-interval '1 minute' where token_hash in(repeat('a7',32),repeat('c7',32));
update private.owner_registration_invitations set created_at=statement_timestamp()-interval '8 days',
 expires_at=statement_timestamp()-interval '1 day',revoked_at=clock_timestamp() where token_hash=repeat('e7',32);
commit;
