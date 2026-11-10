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
select pg_temp.expect_error($q$select public.chat_open('10000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000003')$q$,'conversation_forbidden');
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
rollback;
