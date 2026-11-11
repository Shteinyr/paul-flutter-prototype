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
insert into auth.users(id,phone,phone_confirmed_at) values
 ('70000000-0000-4000-8000-000000000001','12025550101',clock_timestamp()),
 ('70000000-0000-4000-8000-000000000002','+442079460018',clock_timestamp()),
 ('70000000-0000-4000-8000-000000000003','12025550103',null),
 ('70000000-0000-4000-8000-000000000004','12025550104',clock_timestamp());
select private.save_profile(id,jsonb_build_object('name','Phone SQL QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '70000000-%';
insert into private.memberships(user_id) select id from public.profiles where id::text like '70000000-%';
insert into auth.sessions(id,user_id) select ('70100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,('70000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,4)n;
select pg_temp.assert_true(not has_table_privilege('authenticated','private.phone_discovery_settings','SELECT'),'Consent is private');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.phone_discovery_lookup(uuid,uuid,text[])','EXECUTE'),'Browser cannot call privileged lookup directly');
set local role service_role;
select pg_temp.assert_true(public.phone_discovery_status('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001')->>'discoverable'='false','Verified phone is undiscoverable until explicit consent');
select pg_temp.assert_true(public.phone_discovery_status('70000000-0000-4000-8000-000000000003','70100000-0000-4000-8000-000000000003')->>'has_verified_phone'='false','An unconfirmed Auth phone is unverified');
select pg_temp.expect_error($q$select public.phone_discovery_consent('70000000-0000-4000-8000-000000000003','70100000-0000-4000-8000-000000000003',true,repeat('a',64))$q$,'phone_verification_required');
select pg_temp.expect_error($q$select public.phone_discovery_lookup('70000000-0000-4000-8000-000000000003','70100000-0000-4000-8000-000000000003',array['+442079460018'])$q$,'phone_verification_required');
select pg_temp.assert_true(public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['+442079460018'])->'matches'='[]'::jsonb,'Closed numbers reveal no match');
create temp table revision as select private.phone_revision('70000000-0000-4000-8000-000000000002') value;
select pg_temp.expect_error($q$select public.phone_discovery_consent('70000000-0000-4000-8000-000000000002','70100000-0000-4000-8000-000000000002',true,repeat('a',64))$q$,'phone_changed');
select pg_temp.assert_true(public.phone_discovery_consent('70000000-0000-4000-8000-000000000002','70100000-0000-4000-8000-000000000002',true,(select value from revision))->>'discoverable'='true','Consent is bound to the current verified phone revision');
select pg_temp.assert_true(public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array[null,'+442079460018','+12025550101','+442079460018'])->'matches'=jsonb_build_array(
 jsonb_build_object('index',1,'profile_id','70000000-0000-4000-8000-000000000002'),jsonb_build_object('index',3,'profile_id','70000000-0000-4000-8000-000000000002')),'Only the selected consenting account matches at original indexes, self is excluded');
select pg_temp.assert_true((select count(*)=0 from information_schema.columns where table_schema='private' and table_name in('phone_discovery_settings','phone_lookup_days') and column_name in('phone','phones','contacts')),'Raw selected numbers have no persistent column');
reset role;
update auth.users set phone='442079460019',phone_confirmed_at=clock_timestamp() where id='70000000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.assert_true(public.phone_discovery_status('70000000-0000-4000-8000-000000000002','70100000-0000-4000-8000-000000000002')->>'discoverable'='false','Changing the Auth phone invalidates old consent automatically');
select pg_temp.assert_true(public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['+442079460018','+442079460019'])->'matches'='[]'::jsonb,'Neither old nor changed phone is discoverable under stale consent');
select pg_temp.expect_error($q$select public.phone_discovery_consent('70000000-0000-4000-8000-000000000002','70100000-0000-4000-8000-000000000002',true,(select value from revision))$q$,'phone_changed');
select public.phone_discovery_consent('70000000-0000-4000-8000-000000000002','70100000-0000-4000-8000-000000000002',false);
select pg_temp.assert_true((select count(*)=0 from private.phone_discovery_settings where user_id='70000000-0000-4000-8000-000000000002'),'Withdrawing consent removes its stored revision');
select public.phone_discovery_consent('70000000-0000-4000-8000-000000000002','70100000-0000-4000-8000-000000000002',true,private.phone_revision('70000000-0000-4000-8000-000000000002'));
reset role;
delete from private.memberships where user_id='70000000-0000-4000-8000-000000000002';
set local role service_role;
select pg_temp.assert_true(public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['+442079460019'])->'matches'='[]'::jsonb,'An inactive member stays hidden even with prior phone consent');
select pg_temp.expect_error($q$select public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['raw'])$q$,'invalid_request');
reset role;
update private.phone_lookup_days set checks=999 where user_id='70000000-0000-4000-8000-000000000001';
set local role service_role;
select public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['+442079460019']);
select pg_temp.expect_error($q$select public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['+442079460019'])$q$,'rate_limited');
reset role;
update private.phone_lookup_days set day_utc=day_utc-1 where user_id='70000000-0000-4000-8000-000000000001';
set local role service_role;
select public.phone_discovery_lookup('70000000-0000-4000-8000-000000000001','70100000-0000-4000-8000-000000000001',array['+442079460019']);
select pg_temp.assert_true((select checks=1 from private.phone_lookup_days where user_id='70000000-0000-4000-8000-000000000001' and day_utc=(clock_timestamp() at time zone 'UTC')::date),'UTC day boundary renews the lookup budget');
select public.phone_discovery_consent('70000000-0000-4000-8000-000000000004','70100000-0000-4000-8000-000000000004',true,private.phone_revision('70000000-0000-4000-8000-000000000004'));
select public.member_delete_account('70000000-0000-4000-8000-000000000004','70100000-0000-4000-8000-000000000004','70000000-0000-4000-8000-000000000004',gen_random_uuid(),repeat('f',64));
select pg_temp.assert_true((select count(*)=0 from private.phone_discovery_settings where user_id='70000000-0000-4000-8000-000000000004'),'Account deletion immediately removes discovery consent');
select pg_temp.expect_error($q$select public.phone_discovery_consent('70000000-0000-4000-8000-000000000004','70100000-0000-4000-8000-000000000004',true,repeat('a',64))$q$,'session_revoked');
rollback;
