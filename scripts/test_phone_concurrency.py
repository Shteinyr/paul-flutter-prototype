"""Phone consent, verified-number changes and lookup budgets in isolated Paul DB."""
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import time
import uuid


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-mvp') or not sys.argv[2].startswith('paul_mvp'):
        raise SystemExit('Pass the isolated paul-mvp container and paul_mvp database.')
    container, database = sys.argv[1:]
    actor = '70900000-0000-4000-8000-000000000001'
    session = '70910000-0000-4000-8000-000000000001'

    def sql(statement, check=True):
        return subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input="set statement_timeout='10s';" + statement, text=True, capture_output=True, check=check,
        )

    def value(statement):
        return sql(statement).stdout.strip().splitlines()[-1]

    def wait_barrier():
        for _ in range(80):
            if value("select count(*) from pg_stat_activity where application_name='paul-phone-race' and wait_event='PgSleep';") != '0':
                return
            time.sleep(.025)
        raise AssertionError('Transaction did not reach the race barrier')

    sql(f"""insert into auth.users(id,phone,phone_confirmed_at) values('{actor}','12025550101',clock_timestamp());
        select private.save_profile('{actor}',jsonb_build_object('name','Phone concurrency QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb));
        insert into private.memberships(user_id) values('{actor}');
        insert into auth.sessions(id,user_id) values('{session}','{actor}');
        insert into private.phone_lookup_days(user_id,day_utc,checks) values('{actor}',(clock_timestamp() at time zone 'UTC')::date,999);""")
    try:
        lookup = f"select public.phone_discovery_lookup('{actor}','{session}',array['+442079460018']);"
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: sql(lookup, False), range(2)))
        assert sum(result.returncode == 0 for result in results) == 1
        assert all(result.returncode == 0 or 'rate_limited' in result.stderr for result in results)
        assert value(f"select checks from private.phone_lookup_days where user_id='{actor}';") == '1000'
        print('PASS competing final daily lookups admit one check without quota overflow', flush=True)

        revision = value(f"select private.phone_revision('{actor}');")
        consent = f"select public.phone_discovery_consent('{actor}','{session}',true,'{revision}');"
        with ThreadPoolExecutor(max_workers=2) as pool:
            changing = pool.submit(sql, "begin; set local application_name='paul-phone-race';" + f"update auth.users set phone='12025550102',phone_confirmed_at=clock_timestamp() where id='{actor}'; select pg_sleep(1); commit;")
            wait_barrier()
            enabling = pool.submit(sql, consent, False)
            time.sleep(.1)
            assert not enabling.done()
            changing.result()
            assert 'phone_changed' in enabling.result().stderr
        assert value(f"select count(*) from private.phone_discovery_settings where user_id='{actor}';") == '0'
        print('PASS verified-number change serializes before consent and rejects the previous phone revision', flush=True)

        revision = value(f"select private.phone_revision('{actor}');")
        consent = f"select public.phone_discovery_consent('{actor}','{session}',true,'{revision}');"
        sql(consent)
        consent_revision = value(f"select consent_revision from private.phone_discovery_settings where user_id='{actor}';")
        withdraw = f"select public.phone_discovery_consent('{actor}','{session}',false,null,'{consent_revision}');"
        with ThreadPoolExecutor(max_workers=2) as pool:
            withdrawing = pool.submit(sql, "begin; set local application_name='paul-phone-race';" + withdraw + 'select pg_sleep(1); commit;')
            wait_barrier()
            late_enable = pool.submit(sql, consent, False)
            time.sleep(.1)
            assert not late_enable.done()
            withdrawing.result()
            assert 'discovery_state_changed' in late_enable.result().stderr
        status = json.loads(value(f"select public.phone_discovery_status('{actor}','{session}');"))
        assert status['discoverable'] is False
        consent = f"select public.phone_discovery_consent('{actor}','{session}',true,'{revision}','{status['consent_revision']}');"
        sql(consent)
        assert 'discovery_state_changed' in sql(withdraw, False).stderr
        print('PASS withdrawal fences a waiting enable retry and fresh consent fences an old withdrawal retry', flush=True)

        removal = f"select public.member_delete_account('{actor}','{session}','{actor}','{uuid.uuid4()}',repeat('a',64));"
        with ThreadPoolExecutor(max_workers=2) as pool:
            removing = pool.submit(sql, "begin; set local application_name='paul-phone-race';" + removal + 'select pg_sleep(1); commit;')
            wait_barrier()
            enabling = pool.submit(sql, consent, False)
            time.sleep(.1)
            assert not enabling.done()
            removing.result()
            denied = enabling.result()
            assert denied.returncode != 0 and 'session_revoked' in denied.stderr
        assert value(f"select count(*) from private.phone_discovery_settings where user_id='{actor}';") == '0'
        print('PASS account deletion blocks a waiting consent retry and cannot restore discoverability', flush=True)
    finally:
        sql(f"""delete from private.admin_audit where actor_user_id='{actor}';
            delete from private.account_deletions where target_profile_id='{actor}';
            delete from private.phone_discovery_settings where user_id='{actor}';
            delete from private.phone_lookup_days where user_id='{actor}';
            delete from auth.sessions where user_id='{actor}';
            delete from private.memberships where user_id='{actor}';
            delete from public.profiles where id='{actor}';
            delete from auth.users where id='{actor}';""")


if __name__ == '__main__':
    main()
