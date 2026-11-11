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
insert into auth.users(id) select ('48000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,12)n;
select private.save_profile(id,jsonb_build_object('name','Community push QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb))
  from auth.users where id::text like '48000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '48000000-%';
insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
  select id,'48000000-0000-4000-8000-000000000001',clock_timestamp() from auth.users
  where id>'48000000-0000-4000-8000-000000000001' and id<'48000000-0000-4000-8000-000000000012';
insert into auth.sessions(id,user_id) select ('48100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,('48000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,4)n;
select public.push_subscribe(('48000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  ('48100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,('48200000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  'https://fcm.googleapis.com/fcm/send/community-qa-'||n,'B'||repeat('A',86),repeat('B',22)) from generate_series(1,4)n;
delete from auth.sessions where id='48100000-0000-4000-8000-000000000003';
delete from private.memberships where user_id='48000000-0000-4000-8000-000000000004';
select pg_temp.assert_true(not has_function_privilege('authenticated','private.enqueue_community_notifications(uuid)','EXECUTE'),'Enqueue is service-only');
set local role service_role;
create temp table request as select (public.community_create('48000000-0000-4000-8000-000000000001','48100000-0000-4000-8000-000000000001','48300000-0000-4000-8000-000000000001','Design','Private Community text')->>'request_id')::uuid id;
select private.enqueue_community_notifications((select id from request));
select pg_temp.assert_true((select count(*)=2 from private.notification_jobs where request_id=(select id from request)),'Only currently consenting active accounts receive one job each, including author');
select pg_temp.assert_true((select bool_and(message_id is null and conversation_id is null and kind='community_created') from private.notification_jobs where request_id=(select id from request)),'Community and message job shapes stay separate');
select pg_temp.assert_true((select count(*)=0 from private.notification_jobs where request_id=(select id from request) and recipient_user_id not in('48000000-0000-4000-8000-000000000001','48000000-0000-4000-8000-000000000002')),'Nonconsenting, revoked and unregistered users are excluded');
select pg_temp.expect_error($q$insert into private.notification_jobs(kind,recipient_user_id) values('message_created','48000000-0000-4000-8000-000000000001')$q$,'notification_jobs_shape_check');
select public.push_subscribe('48000000-0000-4000-8000-000000000002','48100000-0000-4000-8000-000000000002','48200000-0000-4000-8000-000000000005','https://fcm.googleapis.com/fcm/send/community-late-binding','B'||repeat('A',86),repeat('B',22));
create temp table claims as select * from jsonb_to_recordset(public.push_claim(20)) as x(delivery_id uuid,lease_token uuid);
select pg_temp.assert_true((select count(*)=2 from claims),'Fresh bindings receive no historical broadcast');
create temp table recipient_delivery as select c.* from claims c join private.push_deliveries d on d.id=c.delivery_id where d.binding_id='48200000-0000-4000-8000-000000000002';
select pg_temp.assert_true(public.push_resolve('48000000-0000-4000-8000-000000000002','48100000-0000-4000-8000-000000000002',(select delivery_id from recipient_delivery),'48200000-0000-4000-8000-000000000002')=jsonb_build_object('kind','community','request_id',(select id from request),'state','active'),'Assigned recipient resolves its active request');
create temp table prepared as select public.push_prepare(delivery_id,lease_token) data from recipient_delivery;
select pg_temp.assert_true((select (select count(*)=4 from jsonb_object_keys(data->'payload')) and not (data->'payload' ? 'request_id') and not (data->'payload' ? 'message') from prepared),'Provider payload retains only four existing version/delivery/binding/recipient fields');
select pg_temp.expect_error($q$select public.push_resolve('48000000-0000-4000-8000-000000000002','48100000-0000-4000-8000-000000000002',gen_random_uuid(),'48200000-0000-4000-8000-000000000002')$q$,'push_forbidden');
select pg_temp.expect_error($q$select public.push_resolve('48000000-0000-4000-8000-000000000001','48100000-0000-4000-8000-000000000001',(select delivery_id from recipient_delivery),'48200000-0000-4000-8000-000000000001')$q$,'push_forbidden');
select public.community_close('48000000-0000-4000-8000-000000000001','48100000-0000-4000-8000-000000000001','48300000-0000-4000-8000-000000000002',(select id from request));
select pg_temp.assert_true((select count(*)=0 from public.community_requests where id=(select id from request)),'Close physically deletes the request');
select pg_temp.assert_true((select bool_and(status='cancelled') from private.push_deliveries where job_id in(select id from private.notification_jobs where request_id=(select id from request))),'Close cancels leased delivery');
select pg_temp.assert_true(not public.push_finish((select delivery_id from recipient_delivery),(select lease_token from recipient_delivery),'sent',201),'Cancelled lease cannot report sent');
select pg_temp.assert_true(public.push_resolve('48000000-0000-4000-8000-000000000002','48100000-0000-4000-8000-000000000002',(select delivery_id from recipient_delivery),'48200000-0000-4000-8000-000000000002')->>'state'='unavailable','Historical assigned notification resolves unavailable after close');
select pg_temp.assert_true((select count(*)=2 from private.notification_jobs where request_id=(select id from request)),'Content-free delivery history survives removal');

create temp table expiring as select (public.community_create('48000000-0000-4000-8000-000000000001','48100000-0000-4000-8000-000000000001',gen_random_uuid(),'Design','Expiry text')->>'request_id')::uuid id;
create temp table expiry_claims as select * from jsonb_to_recordset(public.push_claim(20)) as x(delivery_id uuid,lease_token uuid);
update public.community_requests set created_at=clock_timestamp()-interval '31 days',expires_at=clock_timestamp()-interval '1 second' where id=(select id from expiring);
select pg_temp.assert_true((select bool_and(public.push_prepare(delivery_id,lease_token) is null) from expiry_claims),'Dispatch rejects expired requests before maintenance runs');
select pg_temp.assert_true(public.community_expire(200)=1,'Independent maintenance physically removes expired request');

create temp table withdrawing as select (public.community_create('48000000-0000-4000-8000-000000000001','48100000-0000-4000-8000-000000000001',gen_random_uuid(),'Design','Consent text')->>'request_id')::uuid id;
create temp table withdraw_claims as select * from jsonb_to_recordset(public.push_claim(20)) as x(delivery_id uuid,lease_token uuid);
select public.push_unsubscribe('48000000-0000-4000-8000-000000000002','48100000-0000-4000-8000-000000000002','48200000-0000-4000-8000-000000000002');
select pg_temp.assert_true((select public.push_prepare(c.delivery_id,c.lease_token) is null from withdraw_claims c join private.push_deliveries d on d.id=c.delivery_id where d.binding_id='48200000-0000-4000-8000-000000000002'),'Consent withdrawal blocks leased dispatch');
select public.member_delete_account('48000000-0000-4000-8000-000000000001','48100000-0000-4000-8000-000000000001','48000000-0000-4000-8000-000000000001',gen_random_uuid(),repeat('d',64));
select pg_temp.assert_true((select count(*)=0 from public.community_requests where author_profile_id='48000000-0000-4000-8000-000000000001'),'Author deletion invokes Community removal in the same transaction');
select pg_temp.assert_true((select count(*)=0 from private.push_deliveries where status in('pending','leased') and job_id in(select id from private.notification_jobs where kind='community_created' and request_id=(select id from withdrawing))),'Author deletion cancels remaining dispatches');
rollback;
