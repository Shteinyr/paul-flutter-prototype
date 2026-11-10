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
set local role service_role;
select pg_temp.assert_true(public.push_server_config() is null,'Read does not provision absent credentials');
select pg_temp.expect_error($q$select public.push_provision_config('{}'::jsonb)$q$,'invalid_request');
select pg_temp.expect_error($q$select public.push_provision_config(jsonb_build_object('public_key',null,'private_key',repeat('B',43),'worker_secret',repeat('C',43)))$q$,'invalid_request');
create temp table first_config as select public.push_provision_config(jsonb_build_object('public_key',repeat('A',87),'private_key',repeat('B',43),'worker_secret',repeat('C',43))) value;
select pg_temp.assert_true((select value->'enabled'='false'::jsonb from first_config),'Generated configuration starts disabled');
select pg_temp.assert_true(public.push_provision_config(jsonb_build_object('public_key',repeat('D',87),'private_key',repeat('E',43),'worker_secret',repeat('F',43)))=(select value from first_config),'Subsequent provision never rotates canonical credentials');
select pg_temp.expect_error($q$select count(*) from vault.decrypted_secrets$q$,'permission denied');
select pg_temp.assert_true(public.push_config_set_enabled(true),'Explicit activation succeeds');
select pg_temp.assert_true(public.push_server_config()-'enabled'=(select value-'enabled' from first_config),'Activation preserves all key material and origins');
select pg_temp.assert_true(not public.push_config_set_enabled(false),'Explicit deactivation succeeds');
select pg_temp.assert_true(public.push_server_config()=(select value from first_config),'Deactivation preserves canonical settings');
set local role authenticated;
select pg_temp.expect_error($q$select public.push_server_config()$q$,'permission denied');
select pg_temp.expect_error($q$select public.push_provision_config('{}'::jsonb)$q$,'permission denied');
select pg_temp.expect_error($q$select public.push_config_set_enabled(true)$q$,'permission denied');
select pg_temp.expect_error($q$select private.push_runtime_config(null)$q$,'permission denied');
reset role;
rollback;
