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
insert into auth.users(id) values('74000000-0000-4000-8000-000000000001'),('74000000-0000-4000-8000-000000000002');
select private.save_profile('74000000-0000-4000-8000-000000000001',jsonb_build_object('name','Reservation cleanup QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb));
insert into private.memberships(user_id) values('74000000-0000-4000-8000-000000000001');
insert into auth.sessions(id,user_id) values('74010000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001');
insert into private.admin_roles(user_id,role) values('74000000-0000-4000-8000-000000000001','admin');
create temp table complete_profile as select public.admin_prepare_create('74000000-0000-4000-8000-000000000001',gen_random_uuid()) id;
insert into storage.objects(id,bucket_id,name,owner_id) select gen_random_uuid(),'avatars',id::text||'/'||repeat('a',64)||'.png',null from complete_profile;
select public.admin_save_profile('74000000-0000-4000-8000-000000000001',(select id from complete_profile),true,
 (select client_operation_id from private.managed_profile_reservations where profile_id=(select id from complete_profile)),
 jsonb_build_object('name','Independent managed QA','occupation','','summary','Preserved','skills',array['Design'],'searching_skills','[]'::jsonb,'avatar_path',(select id::text||'/'||repeat('a',64)||'.png' from complete_profile)));
create temp table unfinished as select public.admin_prepare_create('74000000-0000-4000-8000-000000000001',gen_random_uuid()) id;
-- Local Storage stand-ins cover both UUID spellings accepted by the upload guard.
insert into storage.objects(id,bucket_id,name,owner_id) select gen_random_uuid(),'avatars',id::text||'/'||repeat('b',64)||'.png',null from unfinished;
insert into storage.objects(id,bucket_id,name,owner_id) select gen_random_uuid(),'avatars',upper(id::text)||'/'||repeat('c',64)||'.png',null from unfinished;
select public.member_delete_account('74000000-0000-4000-8000-000000000001','74010000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','74020000-0000-4000-8000-000000000001',repeat('a',64));
create temp table claim as select * from jsonb_to_recordset(public.account_cleanup_claim('74020000-0000-4000-8000-000000000001',1)) as x(operation_id uuid,lease_token uuid);
select pg_temp.assert_true(jsonb_array_length(public.account_cleanup_prepare((select operation_id from claim),(select lease_token from claim))->'objects')=2,'Unfinished managed files are included in account cleanup');
select pg_temp.assert_true(public.account_cleanup_finish((select operation_id from claim),(select lease_token from claim),true)->>'state'='pending','Unfinished files prevent a false complete result');
select pg_temp.assert_true((select deleted_at is null and name='Independent managed QA' from public.profiles where id=(select id from complete_profile)),'Completed managed profile survives its creator account deletion');
select pg_temp.assert_true((select count(*)=1 from storage.objects where starts_with(name,(select id::text||'/' from complete_profile))),'Completed independent managed profile keeps its photo');
select pg_temp.expect_error($q$insert into storage.objects(id,bucket_id,name,owner_id) select gen_random_uuid(),'avatars',id::text||'/'||repeat('d',64)||'.png',null from unfinished$q$,'profile_unavailable');
-- New Auth users still upload their own photo before invitation registration.
set local role authenticated;
set local request.jwt.claim.sub='74000000-0000-4000-8000-000000000002';
insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','74000000-0000-4000-8000-000000000002/'||repeat('e',64)||'.png','74000000-0000-4000-8000-000000000002');
reset role;
-- These deletes simulate external Storage/Auth API commits only in this isolated DB.
delete from storage.objects where lower(split_part(name,'/',1))=(select id::text from unfinished);
delete from auth.users where id='74000000-0000-4000-8000-000000000001';
update private.account_deletions set next_attempt_at=clock_timestamp()-interval '1 second' where operation_id='74020000-0000-4000-8000-000000000001';
create temp table retry_claim as select * from jsonb_to_recordset(public.account_cleanup_claim('74020000-0000-4000-8000-000000000001',1)) as x(operation_id uuid,lease_token uuid);
select pg_temp.assert_true(public.account_cleanup_finish((select operation_id from retry_claim),(select lease_token from retry_claim),true)->>'state'='complete','Actual unfinished-file and Auth removal permits completion');
select pg_temp.expect_error($q$insert into storage.objects(id,bucket_id,name,owner_id) select gen_random_uuid(),'avatars',upper(id::text)||'/'||repeat('f',64)||'.png',null from unfinished$q$,'profile_unavailable');
select pg_temp.assert_true((select count(*)=1 from storage.objects where starts_with(name,(select id::text||'/' from complete_profile))),'Finishing account cleanup still preserves the completed managed photo');
rollback;
