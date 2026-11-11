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
insert into auth.users(id) select ('86000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,20)n;
select private.save_profile(id,jsonb_build_object('name','MVP Levels QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb))
  from auth.users where id between '86000000-0000-4000-8000-000000000001' and '86000000-0000-4000-8000-000000000005';
insert into private.memberships(user_id) select id from public.profiles where id::text like '86000000-%';
insert into auth.sessions(id,user_id) select ('86100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,('86000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,5)n;
insert into private.admin_roles(user_id,role) values('86000000-0000-4000-8000-000000000005','admin');
create temp table managed as select public.admin_prepare_create('86000000-0000-4000-8000-000000000005',gen_random_uuid()) id;
select public.admin_save_profile('86000000-0000-4000-8000-000000000005',(select id from managed),true,
 (select client_operation_id from private.managed_profile_reservations where profile_id=(select id from managed)),
 jsonb_build_object('name','Global managed QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb));
create temp table before_composer_events as select count(*) n from realtime.messages;
create temp table composers as select
 (public.chat_open('86000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000002')->>'id')::uuid one,
 (public.chat_open('86000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000003')->>'id')::uuid two,
 (public.chat_open('86000000-0000-4000-8000-000000000001',(select id from managed))->>'id')::uuid managed;
grant select on composers,managed to authenticated;
select pg_temp.assert_true(jsonb_array_length(public.chat_list('86000000-0000-4000-8000-000000000002')->'conversations')=0,'Opening a composer hides the empty recipient thread');
select pg_temp.assert_true(jsonb_array_length(public.operator_inbox('86000000-0000-4000-8000-000000000005',(select id from managed))->'conversations')=0,'Managed inbox hides an empty composer');
select public.chat_read('86000000-0000-4000-8000-000000000002',(select one from composers),0);
select public.operator_read('86000000-0000-4000-8000-000000000005',(select id from managed),(select managed from composers),0);
select pg_temp.assert_true((select count(*)=(select n from before_composer_events) from realtime.messages),'Empty composer and read-zero emit no Realtime');
select pg_temp.assert_true((select count(*)=0 from private.first_contact_days),'Many open composers consume no quota');
set local role authenticated;
set local request.jwt.claim.sub='86000000-0000-4000-8000-000000000002';
select pg_temp.assert_true((select count(*)=0 from public.conversations),'Direct RLS hides empty conversations');
select pg_temp.assert_true((select count(*)=0 from public.conversation_members),'Direct RLS hides empty memberships');
reset role;
select pg_temp.assert_true(public.member_capabilities('86000000-0000-4000-8000-000000000001','86100000-0000-4000-8000-000000000001')->>'invited_registrations'='0','Initial count is zero');
select public.chat_send('86000000-0000-4000-8000-000000000001',(select one from composers),'86200000-0000-4000-8000-000000000001','First external message');
select public.chat_send('86000000-0000-4000-8000-000000000001',(select one from composers),'86200000-0000-4000-8000-000000000001','First external message');
select pg_temp.assert_true((select count(*)=1 from private.first_contact_days),'Retry consumes one first-contact receipt');
select pg_temp.expect_error($q$select public.chat_send('86000000-0000-4000-8000-000000000001',(select two from composers),gen_random_uuid(),'Another external peer')$q$,'new_contact_limit_reached');
select pg_temp.assert_true((select last_message_seq=0 from public.conversations where id=(select two from composers)),'Opening early does not bypass first-send quota');
select pg_temp.assert_true(jsonb_array_length(public.chat_list('86000000-0000-4000-8000-000000000003')->'conversations')=0,'Rejected first send creates no visible thread');
select public.chat_send('86000000-0000-4000-8000-000000000002',(select one from composers),gen_random_uuid(),'An incoming conversation can be answered');
select pg_temp.assert_true(not exists(select 1 from private.first_contact_days where actor_profile_id='86000000-0000-4000-8000-000000000002'),'Replying to incoming history is free');
insert into public.connections(user_low,user_high) values('86000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000004');
select public.chat_send('86000000-0000-4000-8000-000000000001',(public.chat_open('86000000-0000-4000-8000-000000000001','86000000-0000-4000-8000-000000000004')->>'id')::uuid,gen_random_uuid(),'Existing contact is free');
set local time zone 'Pacific/Auckland';
select pg_temp.assert_true((public.member_capabilities('86000000-0000-4000-8000-000000000001','86100000-0000-4000-8000-000000000001')->>'quota_resets_at')::timestamptz=((clock_timestamp() at time zone 'UTC')::date+1)::timestamp at time zone 'UTC','Daily boundary is UTC');
set local time zone 'UTC';
update private.first_contact_days set day_utc=(clock_timestamp() at time zone 'UTC')::date-1 where actor_profile_id='86000000-0000-4000-8000-000000000001';
select public.chat_send('86000000-0000-4000-8000-000000000001',(select managed from composers),gen_random_uuid(),'First managed contact through the normal command');
select public.operator_send('86000000-0000-4000-8000-000000000005',(select id from managed),(select managed from composers),gen_random_uuid(),'Manual reply');
select pg_temp.assert_true(exists(select 1 from public.connections where user_low=least('86000000-0000-4000-8000-000000000001'::uuid,(select id from managed)) and user_high=greatest('86000000-0000-4000-8000-000000000001'::uuid,(select id from managed))),'Managed two-way exchange creates the connection');
update public.profiles set skills=array['One','Two','Three','Four','Five','Six'] where id='86000000-0000-4000-8000-000000000001';
select public.save_member_profile('86000000-0000-4000-8000-000000000001',(select to_jsonb(p)||'{"summary":"Edited legacy profile"}'::jsonb from public.profiles p where id='86000000-0000-4000-8000-000000000001'));
select pg_temp.assert_true((select cardinality(skills)=6 from public.profiles where id='86000000-0000-4000-8000-000000000001'),'Legacy offered skills survive unrelated edits');
select pg_temp.expect_error($q$select public.save_member_profile('86000000-0000-4000-8000-000000000001',(select to_jsonb(p)||jsonb_build_object('skills',skills||array['Seven']) from public.profiles p where id='86000000-0000-4000-8000-000000000001'))$q$,'offering_limit_reached');
select public.save_member_profile('86000000-0000-4000-8000-000000000001',(select to_jsonb(p)||jsonb_build_object('skills',skills[1:5]) from public.profiles p where id='86000000-0000-4000-8000-000000000001'));
select public.issue_invitation('86000000-0000-4000-8000-000000000001',repeat('a',64),repeat('b',64));
insert into storage.objects(id,bucket_id,name,owner_id)
select gen_random_uuid(),'avatars',id::text||'/'||repeat('c',64)||'.png',id::text from auth.users where id between '86000000-0000-4000-8000-000000000006' and '86000000-0000-4000-8000-000000000015';
do $$
declare n integer; person uuid; caps jsonb;
begin
  for n in 6..15 loop
    person:=('86000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    perform public.redeem_invitation(person,repeat('a',64),false,jsonb_build_object('name','Invited QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb,'avatar_path',person::text||'/'||repeat('c',64)||'.png'));
    caps:=public.member_capabilities('86000000-0000-4000-8000-000000000001','86100000-0000-4000-8000-000000000001');
    perform pg_temp.assert_true((caps->>'invited_registrations')::int=n-5,'Completed registration increments once');
    perform pg_temp.assert_true((caps->>'can_message_anyone')::boolean=(n>=7),'Messaging unlocks at exactly two');
    perform pg_temp.assert_true((caps->>'can_publish_community')::boolean=(n>=15),'Community unlocks at exactly ten');
    if n=7 then
      perform public.chat_send('86000000-0000-4000-8000-000000000001',(select two from composers),gen_random_uuid(),'Level two permits a new external peer');
    end if;
  end loop;
end;
$$;
select public.redeem_invitation('86000000-0000-4000-8000-000000000006',repeat('a',64),false,'{}');
select public.issue_invitation('86000000-0000-4000-8000-000000000002',repeat('d',64),repeat('e',64));
select public.redeem_invitation('86000000-0000-4000-8000-000000000006',repeat('d',64),false,'{}');
select pg_temp.assert_true(private.invited_registration_count('86000000-0000-4000-8000-000000000001')=10 and private.invited_registration_count('86000000-0000-4000-8000-000000000002')=0,'Repeats and existing-member reconnections do not increase levels');
select pg_temp.assert_true((select uses=10 from private.invitations where token_hash=repeat('a',64)),'Retry retains original invitation use count');
select private.require_community_publisher('86000000-0000-4000-8000-000000000001');
select pg_temp.expect_error($q$select private.require_community_publisher('86000000-0000-4000-8000-000000000002')$q$,'community_locked');
select public.save_member_profile('86000000-0000-4000-8000-000000000001',(select to_jsonb(p)||jsonb_build_object('skills',array(select 'Skill '||n from generate_series(1,101)n)) from public.profiles p where id='86000000-0000-4000-8000-000000000001'));
select pg_temp.assert_true((select cardinality(skills)=101 from public.profiles where id='86000000-0000-4000-8000-000000000001'),'Expanded offering has no fixed count ceiling');
insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','86000000-0000-4000-8000-000000000006/'||repeat('f',64)||'.png','86000000-0000-4000-8000-000000000006');
set local role authenticated;
set local request.jwt.claim.sub='86000000-0000-4000-8000-000000000001';
select pg_temp.assert_true((select count(*)=1 from public.profiles where id='86000000-0000-4000-8000-000000000003'),'Global RLS includes unrelated active members');
select pg_temp.assert_true((select count(*)=1 from public.profiles where id=(select id from managed)),'Global RLS includes active managed profiles');
select pg_temp.assert_true((select count(*)=1 from storage.objects where name like '86000000-0000-4000-8000-000000000006/%'),'Global photos expose only the current avatar version');
select pg_temp.expect_error($q$select public.member_capabilities(auth.uid(),'86100000-0000-4000-8000-000000000001')$q$,'permission denied');
select pg_temp.expect_error($q$select * from private.invited_registrations$q$,'permission denied');
select pg_temp.expect_error($q$select * from private.first_contact_days$q$,'permission denied');
reset role;
select pg_temp.assert_true(public.member_profile('86000000-0000-4000-8000-000000000001','86100000-0000-4000-8000-000000000001',(select id from managed))->'profile'->>'contact_count'='1','Fresh profile returns the real active contact count');
update public.profiles set disabled_at=clock_timestamp() where id=(select id from managed);
select pg_temp.expect_error($q$select public.member_profile('86000000-0000-4000-8000-000000000001','86100000-0000-4000-8000-000000000001',(select id from managed))$q$,'profile_unavailable');
update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id='86100000-0000-4000-8000-000000000001';
select pg_temp.expect_error($q$select public.member_capabilities('86000000-0000-4000-8000-000000000001','86100000-0000-4000-8000-000000000001')$q$,'session_revoked');
rollback;
