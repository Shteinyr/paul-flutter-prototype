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
insert into auth.users(id) select ('78000000-0000-4000-8000-00000000000'||n)::uuid from generate_series(1,4)n;
select private.save_profile(id,jsonb_build_object('name','Push SQL QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '78000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '78000000-%';
insert into auth.sessions(id,user_id) select ('78100000-0000-4000-8000-00000000000'||right(id::text,1))::uuid,id from auth.users where id::text like '78000000-%';
insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values('78000000-0000-4000-8000-000000000005','managed','Managed push QA','','Test',array['Design']);
insert into private.admin_roles(user_id,role) values('78000000-0000-4000-8000-000000000003','admin'),('78000000-0000-4000-8000-000000000004','admin');
insert into private.managed_profile_grants(user_id,profile_id,can_reply) values('78000000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000005',true);
insert into public.connections(user_low,user_high) values
 ('78000000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002'),
 ('78000000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000005');
create temp table threads as select
 (public.chat_open('78000000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002')->>'id')::uuid personal,
 (public.chat_open('78000000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000005')->>'id')::uuid managed;
-- A newly enabled browser must never receive the old outbox as fresh pushes.
select public.chat_send('78000000-0000-4000-8000-000000000001',(select personal from threads),gen_random_uuid(),'Old history');
set local role service_role;
select pg_temp.expect_error($q$select count(*) from auth.sessions$q$,'permission denied');
select public.push_subscribe('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000001','https://fcm.googleapis.com/fcm/send/push-qa-one','B'||repeat('A',86),repeat('B',22));
select public.push_subscribe('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000002','https://fcm.googleapis.com/fcm/send/push-qa-two','B'||repeat('A',86),repeat('B',22));
select public.push_subscribe('78000000-0000-4000-8000-000000000003','78100000-0000-4000-8000-000000000003','78200000-0000-4000-8000-000000000003','https://fcm.googleapis.com/fcm/send/push-qa-operator','B'||repeat('A',86),repeat('B',22));
select public.push_subscribe('78000000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000004','78200000-0000-4000-8000-000000000004','https://fcm.googleapis.com/fcm/send/push-qa-unassigned','B'||repeat('A',86),repeat('B',22));
create temp table bound as select bound_at from private.push_subscriptions where binding_id='78200000-0000-4000-8000-000000000001';
select pg_temp.assert_true(public.push_subscribe('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000009','https://fcm.googleapis.com/fcm/send/push-qa-one','B'||repeat('A',86),repeat('B',22))->>'binding_id'='78200000-0000-4000-8000-000000000001','Parallel tab adopts canonical binding');
select pg_temp.assert_true((select bound_at=(select bound_at from bound) from private.push_subscriptions where binding_id='78200000-0000-4000-8000-000000000001'),'Idempotent subscribe preserves cutoff');
select pg_temp.expect_error($q$select public.push_subscribe('78000000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000004',gen_random_uuid(),'https://fcm.googleapis.com/fcm/send/push-qa-one','B'||repeat('A',86),repeat('B',22))$q$,'binding_conflict');
select pg_temp.expect_error($q$select public.push_unsubscribe('78000000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000004','78200000-0000-4000-8000-000000000001')$q$,'push_forbidden');
select pg_temp.expect_error($q$select public.push_subscribe('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002',gen_random_uuid(),'https://127.0.0.1/private','B'||repeat('A',86),repeat('B',22))$q$,'invalid_request');
select pg_temp.assert_true(jsonb_array_length(public.push_claim(20))=0,'No historical backfill');
reset role;
select public.chat_send('78000000-0000-4000-8000-000000000001',(select personal from threads),gen_random_uuid(),'Private message never in push');
select public.chat_send('78000000-0000-4000-8000-000000000001',(select managed from threads),gen_random_uuid(),'Managed incoming');
set local role service_role;
create temp table claims as select * from jsonb_to_recordset(public.push_claim(20)) as c(delivery_id uuid,lease_token uuid);
select pg_temp.assert_true((select count(*)=3 from claims),'Two devices plus assigned operator only');
select pg_temp.assert_true(jsonb_array_length(public.push_claim(20))=0,'Already leased deliveries never double claim');
create temp table prepared as select c.*,public.push_prepare(c.delivery_id,c.lease_token) data from claims c;
select pg_temp.assert_true((select bool_and(data->'payload' ?& array['version','delivery_id','binding_id','recipient_user_id']) and bool_and((select count(*)=4 from jsonb_object_keys(data->'payload'))) from prepared),'Exact minimal push DTO');
select pg_temp.assert_true((select bool_and(not (data->'payload' ?| array['text','name','conversation_id','managed_profile_id','endpoint'])) from prepared),'No message or profile PII in payload');
create temp table operator_delivery as select p.* from prepared p where data->'payload'->>'recipient_user_id'='78000000-0000-4000-8000-000000000003';
select pg_temp.assert_true(public.push_resolve('78000000-0000-4000-8000-000000000003','78100000-0000-4000-8000-000000000003',(select delivery_id from operator_delivery),'78200000-0000-4000-8000-000000000003')->>'kind'='operator','Resolve uses Auth operator and managed route');
select pg_temp.expect_error($q$select public.push_resolve('78000000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000004',(select delivery_id from operator_delivery),'78200000-0000-4000-8000-000000000003')$q$,'push_forbidden');
update private.managed_profile_grants set revoked_at=clock_timestamp() where user_id='78000000-0000-4000-8000-000000000003';
select pg_temp.assert_true(public.push_prepare((select delivery_id from operator_delivery),(select lease_token from operator_delivery)) is null,'Revocation cancels a claimed operator send before HTTP');
select pg_temp.expect_error($q$select public.push_resolve('78000000-0000-4000-8000-000000000003','78100000-0000-4000-8000-000000000003',(select delivery_id from operator_delivery),'78200000-0000-4000-8000-000000000003')$q$,'push_forbidden');
update private.managed_profile_grants set revoked_at=null where user_id='78000000-0000-4000-8000-000000000003';
select pg_temp.assert_true(not public.push_finish((select delivery_id from operator_delivery),(select lease_token from operator_delivery),'sent',201),'Cancelled fence never acknowledges success');
-- Invalidating one browser does not disable another device or a new generation.
create temp table normal_delivery as select p.* from prepared p where data->'payload'->>'binding_id'='78200000-0000-4000-8000-000000000001';
select pg_temp.assert_true(not public.push_finish((select delivery_id from normal_delivery),null,'sent',201),'NULL fence cannot complete a claim');
select pg_temp.assert_true(public.push_prepare((select delivery_id from normal_delivery),null) is null,'NULL fence cannot disclose endpoint');
select public.push_finish((select delivery_id from normal_delivery),(select lease_token from normal_delivery),'invalid',410);
select pg_temp.assert_true(not (public.push_status('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000001')->>'enabled')::boolean,'410 disables exact binding');
select pg_temp.assert_true((public.push_status('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000002')->>'enabled')::boolean,'Other device remains enabled');
create temp table retry_delivery as select p.* from prepared p where data->'payload'->>'binding_id'='78200000-0000-4000-8000-000000000002';
select public.push_finish((select delivery_id from retry_delivery),(select lease_token from retry_delivery),'retry',503,30);
select pg_temp.assert_true(jsonb_array_length(public.push_claim(20))=0,'Retry backoff prevents immediate reprocessing');
update private.push_deliveries set next_attempt_at=clock_timestamp()-interval '1 second' where id=(select delivery_id from retry_delivery);
create temp table reclaimed as select * from jsonb_to_recordset(public.push_claim(20)) as c(delivery_id uuid,lease_token uuid);
select pg_temp.assert_true((select count(*)=1 from reclaimed),'One due retry reclaimed');
select pg_temp.assert_true(not public.push_finish((select delivery_id from retry_delivery),(select lease_token from retry_delivery),'sent',201),'Stale worker cannot finish new lease');
update private.push_deliveries set lease_until=clock_timestamp()-interval '1 second' where id=(select delivery_id from reclaimed);
select pg_temp.assert_true(public.push_prepare((select delivery_id from reclaimed),(select lease_token from reclaimed)) is null,'Expired lease cannot obtain endpoint');
select pg_temp.assert_true(jsonb_array_length(public.push_claim(20))=1,'Expired claim is recovered');
update private.push_deliveries set lease_until=clock_timestamp()-interval '1 second',attempts=5 where id=(select delivery_id from reclaimed);
select pg_temp.assert_true(jsonb_array_length(public.push_claim(20))=0,'Max attempts stop retries');
select pg_temp.assert_true((select status='failed' from private.push_deliveries where id=(select delivery_id from reclaimed)),'Exhaustion is recorded');
reset role;
-- A committed disable applies to both pre-send and notification click.
select public.chat_send('78000000-0000-4000-8000-000000000001',(select managed from threads),gen_random_uuid(),'Disable check');
set local role service_role;
create temp table disabled_claim as select * from jsonb_to_recordset(public.push_claim(20)) as c(delivery_id uuid,lease_token uuid);
update public.profiles set disabled_at=clock_timestamp() where id='78000000-0000-4000-8000-000000000005';
select pg_temp.assert_true(public.push_prepare((select delivery_id from disabled_claim),(select lease_token from disabled_claim)) is null,'Disabled managed profile blocks claimed send');
update public.profiles set disabled_at=null where id='78000000-0000-4000-8000-000000000005';
reset role;
delete from auth.sessions where id='78100000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.expect_error($q$select public.push_status('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000002')$q$,'session_revoked');
select public.push_subscribe('78000000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000004','78200000-0000-4000-8000-000000000006','https://fcm.googleapis.com/fcm/send/push-qa-two','B'||repeat('A',86),repeat('B',22));
select pg_temp.assert_true((public.push_status('78000000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000004','78200000-0000-4000-8000-000000000006')->>'enabled')::boolean,'A new account may rebind only after old server session ended');
select pg_temp.expect_error($q$select public.push_unsubscribe('78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78200000-0000-4000-8000-000000000006')$q$,'session_revoked');
reset role;
-- Delivery lifetime limits retries independently of the push provider TTL.
select public.chat_send('78000000-0000-4000-8000-000000000001',(select managed from threads),gen_random_uuid(),'Expiry check');
set local role service_role;
create temp table expired_claim as select * from jsonb_to_recordset(public.push_claim(20)) as c(delivery_id uuid,lease_token uuid);
update private.notification_jobs set created_at=clock_timestamp()-interval '24 hours 1 second' where id=(select job_id from private.push_deliveries where id=(select delivery_id from expired_claim));
select pg_temp.assert_true(public.push_prepare((select delivery_id from expired_claim),(select lease_token from expired_claim)) is null,'Expired delivery cannot get endpoint or retry');
select pg_temp.expect_error($q$select public.push_resolve('78000000-0000-4000-8000-000000000003','78100000-0000-4000-8000-000000000003',(select delivery_id from expired_claim),'78200000-0000-4000-8000-000000000003')$q$,'push_forbidden');
reset role;
select public.chat_send('78000000-0000-4000-8000-000000000001',(select managed from threads),gen_random_uuid(),'Expiry margin check');
set local role service_role;
create temp table margin_claim as select * from jsonb_to_recordset(public.push_claim(20)) as c(delivery_id uuid,lease_token uuid);
update private.notification_jobs set created_at=clock_timestamp()-interval '23 hours 59 minutes 40 seconds' where id=(select job_id from private.push_deliveries where id=(select delivery_id from margin_claim));
select pg_temp.assert_true(public.push_prepare((select delivery_id from margin_claim),(select lease_token from margin_claim)) is null,'Final 30 seconds are never dispatched');
update private.admin_roles set revoked_at=clock_timestamp() where user_id='78000000-0000-4000-8000-000000000003';
select pg_temp.expect_error($q$select public.push_resolve('78000000-0000-4000-8000-000000000003','78100000-0000-4000-8000-000000000003',(select delivery_id from operator_delivery),'78200000-0000-4000-8000-000000000003')$q$,'push_forbidden');
update private.admin_roles set revoked_at=null where user_id='78000000-0000-4000-8000-000000000003';
reset role;
update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id='78100000-0000-4000-8000-000000000003';
set local role service_role;
select pg_temp.expect_error($q$select public.push_status('78000000-0000-4000-8000-000000000003','78100000-0000-4000-8000-000000000003','78200000-0000-4000-8000-000000000003')$q$,'session_revoked');
-- Sixteen dead sessions must not permanently fill a member's active-device cap.
insert into private.push_subscriptions(binding_id,user_id,session_id,endpoint,endpoint_hash,p256dh,auth)
select gen_random_uuid(),'78000000-0000-4000-8000-000000000001',gen_random_uuid(),'https://fcm.googleapis.com/fcm/send/dead-'||n,n::text,'B'||repeat('A',86),repeat('B',22) from generate_series(1,16)n;
select public.push_subscribe('78000000-0000-4000-8000-000000000001','78100000-0000-4000-8000-000000000001',gen_random_uuid(),'https://fcm.googleapis.com/fcm/send/live-after-churn','B'||repeat('A',86),repeat('B',22));
select pg_temp.assert_true((select count(*)=17 from private.push_subscriptions where user_id='78000000-0000-4000-8000-000000000001'),'Revoked sessions do not consume device quota');
set local role authenticated;
select pg_temp.expect_error($q$select * from private.push_subscriptions$q$,'permission denied');
select pg_temp.expect_error($q$select public.push_claim(1)$q$,'permission denied');
select pg_temp.expect_error($q$select private.push_session_active('78000000-0000-4000-8000-000000000001','78100000-0000-4000-8000-000000000001')$q$,'permission denied');
select pg_temp.expect_error($q$select public.push_subscribe('78000000-0000-4000-8000-000000000001','78100000-0000-4000-8000-000000000001',gen_random_uuid(),'https://fcm.googleapis.com/fcm/send/forged','B'||repeat('A',86),repeat('B',22))$q$,'permission denied');
reset role;
rollback;
