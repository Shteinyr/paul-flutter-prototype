begin;
create function pg_temp.assert_true(value boolean, description text) returns void language plpgsql as $$
begin
  if value is distinct from true then raise exception 'Assertion failed: %',description; end if;
end;
$$;
create function pg_temp.expect_error(statement text, expected text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then
    if position(expected in sqlerrm)>0 then return; end if;
    raise;
  end;
  raise exception 'Expected failure %',expected;
end;
$$;
insert into auth.users(id) values
 ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002'),
 ('10000000-0000-4000-8000-000000000003'),('10000000-0000-4000-8000-000000000004');
select private.save_profile(id,jsonb_build_object('name','Chat QA','occupation','','summary','Disposable test',
  'skills',array['Flutter'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '10000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '10000000-%' and id::text not like '%004';
insert into public.connections(user_low,user_high) values('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002');
select pg_temp.expect_error($q$select public.chat_open('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000001')$q$,'self_conversation');
select pg_temp.assert_true((public.chat_open('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003')->>'last_message_seq')::int=0,'Global active peer opens an empty composer');
select pg_temp.expect_error($q$select public.chat_list('10000000-0000-4000-8000-000000000004')$q$,'membership_required');
create temp table chat_test_id as select (public.chat_open('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002')->>'id')::uuid id;
select pg_temp.assert_true((public.chat_open('10000000-0000-4000-8000-000000000002','10000000-0000-4000-8000-000000000001')->>'id')::uuid=(select id from chat_test_id),'Canonical pair reuses the same dialogue');
select pg_temp.assert_true((select count(*)=2 from public.conversation_members where conversation_id=(select id from chat_test_id)),'Exactly two participants');
select public.chat_send('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),'20000000-0000-4000-8000-000000000001','One');
select public.chat_send('10000000-0000-4000-8000-000000000002',(select id from chat_test_id),'20000000-0000-4000-8000-000000000002','Two');
select pg_temp.assert_true((public.chat_send('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),'20000000-0000-4000-8000-000000000001','One')->>'replayed')::boolean,'Retry returns original acknowledgement');
select pg_temp.assert_true((select count(*)=2 and max(seq)=2 from public.messages where conversation_id=(select id from chat_test_id)),'Retry never duplicates a message or consumes sequence');
select pg_temp.expect_error($q$select public.chat_send('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),'20000000-0000-4000-8000-000000000001','Changed')$q$,'message_id_conflict');
select pg_temp.expect_error($q$select public.chat_send('10000000-0000-4000-8000-000000000003',(select id from chat_test_id),'20000000-0000-4000-8000-000000000003','Intruder')$q$,'conversation_forbidden');
select pg_temp.expect_error($q$select public.chat_history('10000000-0000-4000-8000-000000000003',(select id from chat_test_id))$q$,'conversation_forbidden');
select pg_temp.expect_error($q$select public.chat_read('10000000-0000-4000-8000-000000000003',(select id from chat_test_id),2)$q$,'conversation_forbidden');
select pg_temp.assert_true(public.chat_history('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),null,null,1)->'messages'->0->>'text'='Two','Latest page bounded');
select pg_temp.assert_true(public.chat_history('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),2,null,1)->'messages'->0->>'text'='One','Older cursor uses strict sequence bound');
select pg_temp.assert_true(public.chat_history('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),null,0,1)->'messages'->0->>'text'='One','Forward cursor starts at earliest missing sequence');
select pg_temp.assert_true((public.chat_list('10000000-0000-4000-8000-000000000001')->'conversations'->0->>'unread_count')::int=1,'Unread excludes outgoing messages');
select public.chat_read('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),2);
select public.chat_read('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),0);
select pg_temp.assert_true((public.chat_list('10000000-0000-4000-8000-000000000001')->'conversations'->0->>'last_read_seq')::int=2,'Read cursor never moves backwards');
select pg_temp.expect_error($q$select public.chat_read('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),100)$q$,'invalid_request');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.chat_send(uuid,uuid,uuid,text)','execute'),'Browser cannot impersonate service RPC user');
select pg_temp.assert_true(not has_table_privilege('authenticated','public.messages','insert'),'Browser cannot bypass send validation');
set local role authenticated;
set local request.jwt.claim.sub='10000000-0000-4000-8000-000000000003';
select pg_temp.assert_true((select count(*)=0 from public.messages),'Third user cannot read messages through Data API');
select pg_temp.assert_true((select count(*)=0 from public.conversations),'Third user cannot discover conversations');
select pg_temp.assert_true((select count(*)=0 from public.conversation_members),'Third user cannot discover participants');
set local request.jwt.claim.sub='10000000-0000-4000-8000-000000000001';
select pg_temp.assert_true((select count(*)=2 from public.messages),'Participant reads authorized history');
set local request.jwt.claim.sub='10000000-0000-4000-8000-000000000004';
select pg_temp.assert_true((select count(*)=0 from public.messages),'Pending membership cannot read history');
reset role;
-- Fresh exchanges, idempotent removal, and the transactional outbox.
select public.issue_invitation('10000000-0000-4000-8000-000000000001',repeat('9',64),repeat('8',64));
select public.redeem_invitation('10000000-0000-4000-8000-000000000002',repeat('9',64),false,'{}');
select public.chat_disconnect('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000001');
select pg_temp.assert_true(not (public.redeem_invitation('10000000-0000-4000-8000-000000000002',repeat('9',64),false,'{}')->>'connected')::boolean,'Old invite replay reports current disconnected state');
select pg_temp.assert_true((select connection_start_seq=2 from public.conversations where id=(select id from chat_test_id)),'Removal starts a precise new sequence epoch');
select public.chat_send('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),'20000000-0000-4000-8000-000000000001','One');
select pg_temp.assert_true(not exists(select 1 from public.connections where user_low='10000000-0000-4000-8000-000000000001'),'Retrying old history cannot reconnect');
select public.chat_send('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),'20000000-0000-4000-8000-000000000003','Fresh A');
select pg_temp.assert_true(not exists(select 1 from public.connections where user_low='10000000-0000-4000-8000-000000000001'),'One fresh sender does not reconnect');
select pg_temp.assert_true((public.chat_send('10000000-0000-4000-8000-000000000002',(select id from chat_test_id),'20000000-0000-4000-8000-000000000004','Fresh B')->>'connected')::boolean,'Both fresh senders reconnect once');
select pg_temp.assert_true((select count(*)=4 from private.notification_jobs where conversation_id=(select id from chat_test_id)),'One private outbox event per persisted message');
select public.chat_disconnect('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000001');
select pg_temp.assert_true(exists(select 1 from public.connections where user_low='10000000-0000-4000-8000-000000000001'),'Retry of old removal cannot delete a new connection');
select pg_temp.expect_error($q$select public.chat_disconnect('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003','40000000-0000-4000-8000-000000000001')$q$,'operation_id_conflict');
select public.chat_disconnect('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002','40000000-0000-4000-8000-000000000002');
select public.chat_send('10000000-0000-4000-8000-000000000001',(select id from chat_test_id),'20000000-0000-4000-8000-000000000005','Before failure');
create function pg_temp.fail_outbox() returns trigger language plpgsql as $$begin raise exception 'outbox_failed'; end;$$;
create trigger chat_test_fail_outbox before insert on private.notification_jobs for each row execute function pg_temp.fail_outbox();
select pg_temp.expect_error($q$select public.chat_send('10000000-0000-4000-8000-000000000002',(select id from chat_test_id),'20000000-0000-4000-8000-000000000006','Must roll back')$q$,'outbox_failed');
drop trigger chat_test_fail_outbox on private.notification_jobs;
select pg_temp.assert_true((select last_message_seq=5 from public.conversations where id=(select id from chat_test_id)),'Outbox failure rolls back sequence');
select pg_temp.assert_true((select count(*)=5 from public.messages where conversation_id=(select id from chat_test_id)),'Outbox failure rolls back message');
select pg_temp.assert_true(not exists(select 1 from public.connections where user_low='10000000-0000-4000-8000-000000000001'),'Outbox failure rolls back reconnection');
select pg_temp.assert_true(not has_table_privilege('authenticated','private.notification_jobs','select'),'Browser cannot read notification outbox');
rollback;
