begin;
create function pg_temp.expect_error(statement text, expected text) returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if position(expected in sqlerrm) > 0 then return; end if;
    raise;
  end;
  raise exception 'Expected failure % from %', expected, statement;
end;
$$;
create function pg_temp.assert_true(value boolean, description text) returns void language plpgsql as $$
begin
  if value is distinct from true then raise exception 'Assertion failed: %', description; end if;
end;
$$;

insert into auth.users(id) values
  ('00000000-0000-4000-8000-000000000001'),
  ('00000000-0000-4000-8000-000000000002'),
  ('00000000-0000-4000-8000-000000000003'),
  ('00000000-0000-4000-8000-000000000004');
select private.save_profile('00000000-0000-4000-8000-000000000001',
  '{"name":"Test inviter","occupation":"Designer","summary":"Test profile","skills":["Design"],"searching_skills":[]}');
insert into private.memberships(user_id) values('00000000-0000-4000-8000-000000000001');
insert into storage.objects(id, bucket_id, name, owner_id) values
  (gen_random_uuid(), 'avatars', '00000000-0000-4000-8000-000000000002/' || repeat('a',64) || '.png', '00000000-0000-4000-8000-000000000002');

select public.issue_invitation('00000000-0000-4000-8000-000000000001', repeat('a',64), repeat('b',64));
select pg_temp.assert_true((select expires_at - created_at = interval '15 minutes' from private.invitations where token_hash=repeat('a',64)), 'Lifetime is exactly 15 minutes');
create temp table original_expiry as select expires_at from private.invitations where token_hash=repeat('a',64);
select public.issue_invitation('00000000-0000-4000-8000-000000000001', repeat('a',64), repeat('b',64));
select pg_temp.assert_true((select i.expires_at=o.expires_at from private.invitations i cross join original_expiry o where token_hash=repeat('a',64)), 'Retry does not extend expiry');
select public.check_invitation(repeat('b',64), true);
select pg_temp.expect_error($q$select public.issue_invitation('00000000-0000-4000-8000-000000000003', repeat('c',64), repeat('d',64))$q$, 'membership_required');
select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000001', repeat('a',64), false, '{}')$q$, 'own_invitation');
select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000003', repeat('a',64), false, '{}')$q$, 'invalid_profile');
select pg_temp.assert_true(not exists(select 1 from private.memberships where user_id='00000000-0000-4000-8000-000000000003'), 'Failed draft does not activate membership');
select pg_temp.assert_true(not private.valid_skills(array['Flutter',' flutter '], true), 'Duplicate skills are rejected within one list');
select pg_temp.assert_true(private.valid_skills(array['Flutter'], true) and private.valid_skills(array['Flutter'], false), 'Overlap between offered and searching is valid');

select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000002', repeat('a',64), false,
  '{"name":"Test invitee","occupation":"","summary":"Test profile","skills":["Engineering"],"searching_skills":[]}')$q$, 'invalid_profile');
select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000002', repeat('a',64), false,
  jsonb_build_object('name','Test','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb,
    'avatar_path','00000000-0000-4000-8000-000000000002/' || repeat('b',64) || '.png'))$q$, 'invalid_profile');
select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000003', repeat('a',64), false,
  jsonb_build_object('name','Test','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb,
    'avatar_path','00000000-0000-4000-8000-000000000002/' || repeat('a',64) || '.png'))$q$, 'invalid_profile');
select public.redeem_invitation('00000000-0000-4000-8000-000000000002', repeat('a',64), false,
  jsonb_build_object('name','Test invitee','occupation','','summary','Test profile','skills',array[repeat(U&'a\0301',64)],
    'searching_skills','[]'::jsonb,'avatar_path','00000000-0000-4000-8000-000000000002/' || repeat('a',64) || '.png'));
select public.redeem_invitation('00000000-0000-4000-8000-000000000002', repeat('a',64), false, '{}');
select pg_temp.assert_true((select count(*)=1 from public.connections), 'Exactly one connection after retry');
select pg_temp.assert_true((select uses=1 from private.invitations where token_hash=repeat('a',64)), 'Retry does not consume another use');
select pg_temp.assert_true((public.member_network('00000000-0000-4000-8000-000000000002')->'profile'->>'contact_count')::int=1, 'Network contains a real connection count');
select pg_temp.assert_true(public.member_network('00000000-0000-4000-8000-000000000003')->'profile'='null'::jsonb, 'Pending network has no profile');

-- Browser roles cannot activate themselves, issue RPCs or mutate connections.
select pg_temp.assert_true(not has_function_privilege('anon','public.check_invitation(text,boolean)','execute'), 'Anon cannot brute-force a direct RPC');
select pg_temp.assert_true(not has_function_privilege('authenticated','public.redeem_invitation(uuid,text,boolean,jsonb)','execute'), 'Authenticated cannot spoof the service RPC user');
select pg_temp.assert_true(not has_table_privilege('authenticated','public.profiles','insert'), 'Browser cannot create an active profile directly');
select pg_temp.assert_true(not has_table_privilege('authenticated','public.connections','insert'), 'Browser cannot insert arbitrary connections');

set local role authenticated;
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000003';
select pg_temp.assert_true((select count(*)=0 from public.profiles), 'Pending member sees no profiles');
select pg_temp.assert_true((select count(*)=0 from public.connections), 'Pending member sees no connections');
set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000002';
select pg_temp.assert_true((select count(*)=2 from public.profiles), 'Invitee sees self and inviter');
select pg_temp.assert_true((select count(*)=1 from public.connections), 'Invitee sees actual connection');
reset role;

select public.issue_invitation('00000000-0000-4000-8000-000000000001', repeat('c',64), repeat('d',64));
update private.invitations set created_at=t.at-interval '16 minutes', expires_at=t.at-interval '1 minute'
  from (select clock_timestamp() at) t where token_hash=repeat('c',64);
select pg_temp.expect_error($q$select public.check_invitation(repeat('c',64), false)$q$, 'invalid_invitation');
select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000003', repeat('c',64), false, '{}')$q$, 'invalid_invitation');
select public.issue_invitation('00000000-0000-4000-8000-000000000001', repeat('e',64), repeat('f',64));
select public.revoke_invitation('00000000-0000-4000-8000-000000000001', (select id from private.invitations where token_hash=repeat('e',64)));
select pg_temp.expect_error($q$select public.check_invitation(repeat('e',64), false)$q$, 'invalid_invitation');

select public.issue_invitation('00000000-0000-4000-8000-000000000001', repeat('1',64), repeat('2',64));
update private.invitations set max_uses=1 where token_hash=repeat('1',64);
select public.redeem_invitation('00000000-0000-4000-8000-000000000002', repeat('1',64), false, '{}');
select pg_temp.expect_error($q$select public.redeem_invitation('00000000-0000-4000-8000-000000000003', repeat('1',64), false, '{}')$q$, 'invalid_invitation');
select pg_temp.assert_true((select count(*)=1 from public.connections), 'Different invitation does not duplicate the same pair');

select pg_temp.assert_true(public.invite_request_limit('test-budget',2,60), 'First request allowed');
select pg_temp.assert_true(public.invite_request_limit('test-budget',2,60), 'Second request allowed');
select pg_temp.assert_true(not public.invite_request_limit('test-budget',2,60), 'Excess request rejected');
select pg_temp.assert_true(not exists(select 1 from public.profiles where id='00000000-0000-4000-8000-000000000003'), 'Rejected invitation never leaves an active profile');
rollback;
