begin;
create function pg_temp.assert_true(v boolean,d text) returns void language plpgsql as $$begin if v is distinct from true then raise exception 'Assertion: %',d;end if;end;$$;
create function pg_temp.expect_error(s text,e text) returns void language plpgsql as $$begin begin execute s;exception when others then if position(e in sqlerrm)>0 then return;end if;raise;end;raise exception 'Expected %',e;end;$$;
insert into auth.users(id) values('73000000-0000-4000-8000-000000000001'),('73000000-0000-4000-8000-000000000002');
insert into auth.sessions(id,user_id) values('73000000-1111-4111-8111-000000000001','73000000-0000-4000-8000-000000000001');
insert into public.profiles(id,name,occupation,summary,skills) values('73000000-0000-4000-8000-000000000001','Photo QA','','Test',array['Design']);
insert into private.memberships(user_id) values('73000000-0000-4000-8000-000000000001');
select pg_temp.assert_true(not (select enabled from private.avatar_cleanup_settings),'Disabled before reviewed activation');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.avatar_cleanup_adopt(jsonb)','execute'),'Clients cannot adopt historical objects');
select pg_temp.assert_true(not has_function_privilege('anon','public.avatar_upload_begin(text)','execute'),'No anon upload lease');
set local role authenticated;
set local request.jwt.claim.sub='73000000-0000-4000-8000-000000000001';
set local request.jwt.claims='{"session_id":"73000000-1111-4111-8111-000000000001"}';
select public.avatar_upload_begin('73000000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png');
select pg_temp.expect_error($q$select public.avatar_upload_begin('73000000-0000-4000-8000-000000000002/'||repeat('a',64)||'.png')$q$,'sign_in_required');
select pg_temp.expect_error($q$select public.avatar_cleanup_claim()$q$,'permission denied');
reset role;
insert into storage.objects(id,bucket_id,name,owner_id) values
 ('73000000-2222-4222-8222-000000000001','avatars','73000000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png','73000000-0000-4000-8000-000000000001'),
 ('73000000-2222-4222-8222-000000000002','avatars','73000000-0000-4000-8000-000000000001/'||repeat('b',64)||'.png','73000000-0000-4000-8000-000000000001'),
 ('73000000-2222-4222-8222-000000000003','avatars','73000000-0000-4000-8000-000000000001/'||repeat('c',64)||'.png','73000000-0000-4000-8000-000000000001');
update public.profiles set avatar_path='73000000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png' where id='73000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.assert_true(public.avatar_cleanup_claim()='[]'::jsonb,'No claims while OFF');
select public.avatar_cleanup_set_enabled(true);
select pg_temp.assert_true(public.avatar_cleanup_claim()='[]'::jsonb,'New/failure/active uploads have24h grace');
reset role;
update private.avatar_uploads set protected_until=clock_timestamp()-interval '1 second' where path in(
 '73000000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png',
 '73000000-0000-4000-8000-000000000001/'||repeat('b',64)||'.png');
set local role service_role;
select pg_temp.assert_true(jsonb_array_length(public.avatar_cleanup_claim())=1,'Only abandoned old upload claimed; current and fresh protected');
reset role;
-- Current photo replacement: old known ref becomes eligible after grace, new stays.
update public.profiles set avatar_path='73000000-0000-4000-8000-000000000001/'||repeat('c',64)||'.png' where id='73000000-0000-4000-8000-000000000001';
set local role service_role;
select pg_temp.assert_true(jsonb_array_length(public.avatar_cleanup_claim())=1,'Successfully replaced old photo now collectable');
reset role;
do $$declare old_path text:='73000000-0000-4000-8000-000000000001/'||repeat('a',64)||'.png';old_lease uuid;next_lease uuid;begin
 select lease_token into old_lease from private.avatar_uploads where path=old_path;
 perform pg_temp.assert_true((public.avatar_cleanup_prepare(old_path,old_lease)->>'exists')::boolean,'Prepare known object');
 perform public.avatar_cleanup_set_enabled(false);
 perform pg_temp.assert_true(public.avatar_cleanup_prepare(old_path,old_lease) is null,'Disable blocks not-yet-issued deletes');
 perform public.avatar_cleanup_set_enabled(true);
 perform pg_temp.expect_error(format('update public.profiles set avatar_path=%L where id=%L',old_path,'73000000-0000-4000-8000-000000000001'),'avatar_retired');
 perform pg_temp.expect_error(format('select private.avatar_begin(%L,%L)',old_path,'upload'),'avatar_retired');
 -- An HTTP DELETE may already be in flight when a lease expires. Its path must
 -- stay permanently fenced even after another worker takes over.
 update private.avatar_uploads set lease_until=clock_timestamp()-interval '1 second' where path=old_path;
 perform public.avatar_cleanup_claim();
 select lease_token into next_lease from private.avatar_uploads where path=old_path;
 perform pg_temp.assert_true(next_lease<>old_lease,'Expired lease reclaimed');
 perform pg_temp.assert_true(public.avatar_cleanup_prepare(old_path,old_lease) is null,'Stale prepare returns no path');
 perform pg_temp.assert_true(public.avatar_cleanup_finish(old_path,old_lease,true) is null,'Stale completion cannot acknowledge new lease');
 perform pg_temp.expect_error(format('update storage.objects set owner_id=owner_id where name=%L',old_path),'avatar_retired');
 perform pg_temp.assert_true(public.avatar_cleanup_finish(old_path,next_lease,false)->>'state'='deleting','Partial failure stays retired and retryable');
 perform pg_temp.assert_true((select last_error='storage_unavailable' and next_attempt_at>clock_timestamp() from private.avatar_uploads where path=old_path),'Backoff records safe error');
 -- Local Storage stand-in only: production worker never deletes SQL metadata.
 delete from storage.objects where name=old_path;
 update private.avatar_uploads set next_attempt_at=clock_timestamp()-interval '1 second' where path=old_path;
 perform public.avatar_cleanup_claim();
 select lease_token into next_lease from private.avatar_uploads where path=old_path;
 perform pg_temp.assert_true(public.avatar_cleanup_finish(old_path,next_lease,true)->>'state'='deleted','Retry confirms absent object');
 perform pg_temp.expect_error(format('select private.avatar_begin(%L,%L)',old_path,'upload'),'avatar_retired');
end;$$;
-- Legacy paths are untouched until reviewed ID-bound import; no current refs.
alter table storage.objects disable trigger zz_avatar_lifecycle;
insert into storage.objects(id,bucket_id,name,owner_id) values
 ('73000000-2222-4222-8222-000000000004','avatars','73000000-0000-4000-8000-000000000001/'||repeat('d',64)||'.png','73000000-0000-4000-8000-000000000001');
alter table storage.objects enable trigger zz_avatar_lifecycle;
set local role service_role;
select pg_temp.assert_true(public.avatar_cleanup_inventory() @> jsonb_build_array(jsonb_build_object('category','untracked')),'Untracked historical object reported, not claimed');
select pg_temp.expect_error($q$select public.avatar_cleanup_adopt(jsonb_build_array(jsonb_build_object('path','73000000-0000-4000-8000-000000000001/'||repeat('d',64)||'.png','object_id','73000000-2222-4222-8222-000000000099')))$q$,'inventory_changed');
select pg_temp.assert_true(public.avatar_cleanup_adopt(jsonb_build_array(jsonb_build_object('path','73000000-0000-4000-8000-000000000001/'||repeat('d',64)||'.png','object_id','73000000-2222-4222-8222-000000000004')))=1,'Reviewed ID adopted');
select pg_temp.assert_true(public.avatar_cleanup_adopt(jsonb_build_array(jsonb_build_object('path','73000000-0000-4000-8000-000000000001/'||repeat('d',64)||'.png','object_id','73000000-2222-4222-8222-000000000004')))=0,'Import idempotent');
reset role;
select pg_temp.assert_true((select protected_until>clock_timestamp()+interval '23 hours' from private.avatar_uploads where source='legacy'),'Legacy receives NEW full grace');
update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id='73000000-1111-4111-8111-000000000001';
set local role authenticated;
select pg_temp.expect_error($q$select public.avatar_upload_begin('73000000-0000-4000-8000-000000000001/'||repeat('e',64)||'.png')$q$,'session_revoked');
reset role;
rollback;
