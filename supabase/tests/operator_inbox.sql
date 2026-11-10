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
insert into auth.users(id) select ('44000000-0000-4000-8000-00000000000'||n)::uuid from generate_series(1,4)n;
select private.save_profile(id,jsonb_build_object('name','Operator QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '44000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '44000000-%';
insert into private.admin_roles(user_id,role) values ('44000000-0000-4000-8000-000000000001','admin'),('44000000-0000-4000-8000-000000000002','admin');
insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values
 ('44000000-0000-4000-8000-000000000005','managed','Managed operator QA','','Test',array['Design']),
 ('44000000-0000-4000-8000-000000000006','managed','Other managed QA','','Test',array['Design']);
insert into private.managed_profile_grants(user_id,profile_id,can_reply,can_manage) values
 ('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',true,true),
 ('44000000-0000-4000-8000-000000000002','44000000-0000-4000-8000-000000000006',true,true);
-- Explicit local QA-only connections. No administrative endpoint creates these.
insert into public.connections(user_low,user_high) values
 ('44000000-0000-4000-8000-000000000003','44000000-0000-4000-8000-000000000005'),
 ('44000000-0000-4000-8000-000000000003','44000000-0000-4000-8000-000000000004');
create temp table threads as select
 (public.chat_open('44000000-0000-4000-8000-000000000003','44000000-0000-4000-8000-000000000005')->>'id')::uuid managed,
 (public.chat_open('44000000-0000-4000-8000-000000000003','44000000-0000-4000-8000-000000000004')->>'id')::uuid personal;
select public.chat_send('44000000-0000-4000-8000-000000000003',(select managed from threads),'44100000-0000-4000-8000-000000000001','Incoming QA');
select public.chat_send('44000000-0000-4000-8000-000000000003',(select personal from threads),'44100000-0000-4000-8000-000000000002','Personal QA');
select pg_temp.assert_true(jsonb_array_length(public.operator_inbox('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005')->'conversations')=1,'Assigned inbox contains only its conversations');
select pg_temp.assert_true((public.operator_inbox('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005')->'conversations'->0->>'unread_count')::int=1,'Incoming unread counter belongs to managed profile');
select pg_temp.expect_error($q$select public.operator_inbox('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000006')$q$,'managed_profile_forbidden');
select pg_temp.expect_error($q$select public.operator_history('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select personal from threads))$q$,'conversation_forbidden');
select pg_temp.expect_error($q$select public.operator_inbox('44000000-0000-4000-8000-000000000003','44000000-0000-4000-8000-000000000005')$q$,'admin_forbidden');
select public.operator_send('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads),'44100000-0000-4000-8000-000000000003','Manual reply QA');
select pg_temp.assert_true((select sender_profile_id='44000000-0000-4000-8000-000000000005' and actor_user_id='44000000-0000-4000-8000-000000000001' from public.messages where conversation_id=(select managed from threads) and seq=2),'Sender and real actor are distinct and correct');
select pg_temp.assert_true((public.operator_send('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads),'44100000-0000-4000-8000-000000000003','Manual reply QA')->>'replayed')::boolean,'Reply retry acknowledges original message');
select pg_temp.assert_true((select count(*)=1 from private.admin_audit where actor_user_id='44000000-0000-4000-8000-000000000001' and profile_id='44000000-0000-4000-8000-000000000005' and action='reply_as'),'Manual reply audit commits once');
select pg_temp.assert_true((select count(*)=2 from public.messages where conversation_id=(select managed from threads)),'Retry never duplicates the reply');
select pg_temp.expect_error($q$select public.operator_send('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads),'44100000-0000-4000-8000-000000000003','Changed')$q$,'message_id_conflict');
select pg_temp.assert_true(exists(select 1 from realtime.messages where topic='admin:user:44000000-0000-4000-8000-000000000001' and payload='{"changed":true}'::jsonb and private),'Assigned operator receives private metadata hint');
select pg_temp.assert_true(not exists(select 1 from realtime.messages where topic='admin:user:44000000-0000-4000-8000-000000000002' and payload='{"changed":true}'::jsonb),'Other operator never receives an unrelated message hint');
select public.operator_read('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads),2);
select pg_temp.assert_true((public.operator_inbox('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005')->'conversations'->0->>'unread_count')::int=0,'Read cursor updates intended managed profile');
-- A managed message never creates a previously removed audience connection.
select public.chat_disconnect('44000000-0000-4000-8000-000000000003','44000000-0000-4000-8000-000000000005','44100000-0000-4000-8000-000000000004');
select public.chat_send('44000000-0000-4000-8000-000000000003',(select managed from threads),'44100000-0000-4000-8000-000000000005','Fresh incoming QA');
select public.operator_send('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads),'44100000-0000-4000-8000-000000000006','Fresh manual QA');
select pg_temp.assert_true(not exists(select 1 from public.connections where user_low='44000000-0000-4000-8000-000000000003' and user_high='44000000-0000-4000-8000-000000000005'),'No managed automatic reconnection before audience agreement');
-- Read-only history survives disabling. New sends do not.
select public.admin_set_profile_enabled('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',false,'44100000-0000-4000-8000-000000000007',(select updated_at from public.profiles where id='44000000-0000-4000-8000-000000000005'));
select pg_temp.assert_true(jsonb_array_length(public.operator_history('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads))->'messages')=4,'Assigned operator retains disabled history');
select pg_temp.expect_error($q$select public.operator_send('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads),'44100000-0000-4000-8000-000000000008','Disabled send')$q$,'managed_profile_forbidden');
select public.admin_set_profile_enabled('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',true,'44100000-0000-4000-8000-000000000009',(select updated_at from public.profiles where id='44000000-0000-4000-8000-000000000005'));
update private.managed_profile_grants set revoked_at=clock_timestamp() where profile_id='44000000-0000-4000-8000-000000000005';
select pg_temp.expect_error($q$select public.operator_history('44000000-0000-4000-8000-000000000001','44000000-0000-4000-8000-000000000005',(select managed from threads))$q$,'managed_profile_forbidden');
insert into private.managed_profile_grants(user_id,profile_id,can_reply) values('44000000-0000-4000-8000-000000000002','44000000-0000-4000-8000-000000000005',true);
select public.operator_send('44000000-0000-4000-8000-000000000002','44000000-0000-4000-8000-000000000005',(select managed from threads),'44100000-0000-4000-8000-000000000003','Other operator same client ID');
select pg_temp.assert_true((select count(distinct actor_user_id)=2 from public.messages where conversation_id=(select managed from threads) and client_message_id='44100000-0000-4000-8000-000000000003'),'Same client ID remains actor-scoped for a shared managed sender');
create temp table before_hint as select count(*) n from realtime.messages where topic='admin:user:44000000-0000-4000-8000-000000000001' and payload='{"changed":true}'::jsonb;
select public.chat_send('44000000-0000-4000-8000-000000000003',(select managed from threads),'44100000-0000-4000-8000-000000000010','After grant revoke');
select pg_temp.assert_true((select count(*)=(select n from before_hint) from realtime.messages where topic='admin:user:44000000-0000-4000-8000-000000000001' and payload='{"changed":true}'::jsonb),'Revoked operator receives no new message hints');
grant select on threads to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub','44000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true((select count(*)=0 from public.messages where conversation_id in (select managed from threads union all select personal from threads)),'Admin has no generic private-chat RLS bypass');
select pg_temp.expect_error($q$select public.operator_inbox(auth.uid(),'44000000-0000-4000-8000-000000000005')$q$,'permission denied');
select pg_temp.expect_error($q$insert into public.messages(conversation_id,seq,sender_profile_id,actor_user_id,client_message_id,text) select managed,6,'44000000-0000-4000-8000-000000000005',auth.uid(),gen_random_uuid(),'Forged insert' from threads$q$,'permission denied');
select set_config('realtime.topic','admin:user:44000000-0000-4000-8000-000000000002',true);
select pg_temp.assert_true((select count(*)=0 from realtime.messages),'Foreign admin private topic rejected');
select set_config('realtime.topic','admin:user:44000000-0000-4000-8000-000000000001',true);
select pg_temp.assert_true(exists(select 1 from realtime.messages),'Own admin metadata inbox allowed by current server role');
select pg_temp.assert_true(not exists(select 1 from realtime.messages where payload ? 'text'),'Operator hints never expose message text');
select pg_temp.expect_error($q$insert into realtime.messages(topic,extension,payload,event,private) values('admin:user:44000000-0000-4000-8000-000000000001','broadcast','{}'::jsonb,'changed',true)$q$,'row-level security');
reset role;
rollback;
