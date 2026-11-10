begin;
create function pg_temp.assert_true(value boolean,description text) returns void language plpgsql as $$
begin if value is distinct from true then raise exception 'Assertion failed: %',description; end if; end;
$$;
insert into auth.users(id) values
 ('50000000-0000-4000-8000-000000000001'),('50000000-0000-4000-8000-000000000002'),('50000000-0000-4000-8000-000000000003');
select private.save_profile(id,jsonb_build_object('name','Realtime QA','occupation','','summary','Test',
  'skills',array['Flutter'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '50000000-%';
insert into private.memberships(user_id) select id from auth.users where id::text like '50000000-%';
insert into public.connections(user_low,user_high) values('50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000002');
create temp table chat_realtime_id as select (public.chat_open('50000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000002')->>'id')::uuid id;
select public.chat_send('50000000-0000-4000-8000-000000000001',(select id from chat_realtime_id),'50000000-0000-4000-8000-000000000004','Private test message');
select pg_temp.assert_true((select count(*)=2 from realtime.messages where payload->>'conversation_id'=(select id::text from chat_realtime_id)),'Message emits only two participant signals');
select pg_temp.assert_true((select bool_and(private and not(payload?'text') and not(payload?'name')) from realtime.messages where topic like 'chat:user:50000000-%'),'Private signals omit message text and identity details');
select public.chat_read('50000000-0000-4000-8000-000000000002',(select id from chat_realtime_id),1);
select public.chat_read('50000000-0000-4000-8000-000000000002',(select id from chat_realtime_id),1);
select pg_temp.assert_true((select count(*)=1 from realtime.messages where payload?'read_seq' and topic='chat:user:50000000-0000-4000-8000-000000000002'),'Only changed read cursors emit a signal to their own account');
set local role authenticated;
set local request.jwt.claim.sub='50000000-0000-4000-8000-000000000001';
set local realtime.topic='chat:user:50000000-0000-4000-8000-000000000001';
select pg_temp.assert_true((select count(*)>0 from realtime.messages),'Active member receives own private inbox');
set local realtime.topic='chat:user:50000000-0000-4000-8000-000000000002';
select pg_temp.assert_true((select count(*)=0 from realtime.messages),'Participant cannot subscribe to the other account inbox');
set local request.jwt.claim.sub='50000000-0000-4000-8000-000000000003';
select pg_temp.assert_true((select count(*)=0 from realtime.messages),'Third account cannot subscribe to participant inbox');
set local realtime.topic='chat:user:50000000-0000-4000-8000-000000000003';
do $$begin
  begin
    insert into realtime.messages(topic,extension,payload,event,private)
      values('chat:user:50000000-0000-4000-8000-000000000003','broadcast','{}','changed',true);
    raise exception 'Client publishing was unexpectedly permitted';
  exception when insufficient_privilege then null; end;
end;$$;
reset role;
rollback;
