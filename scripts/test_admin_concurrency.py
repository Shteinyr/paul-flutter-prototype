"""Profile authorization/disable race gate in an explicitly isolated Paul DB."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import time


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-') or not sys.argv[2].startswith('paul_'):
        raise SystemExit('Pass the isolated Paul container and Paul database names.')
    container, database = sys.argv[1:]
    actor = '42200000-0000-4000-8000-000000000001'
    profile = '42200000-0000-4000-8000-000000000002'

    def sql(statement, check=True):
        return subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input=statement, text=True, capture_output=True, check=check,
        )

    def wait_barrier():
        for _ in range(60):
            if sql("select count(*) from pg_stat_activity where application_name='paul-admin-race' and wait_event='PgSleep';").stdout.strip() != '0':
                return
            time.sleep(.05)
        raise AssertionError('Transaction never reached the lock barrier')

    sql(f"""insert into auth.users values('{actor}');
      select private.save_profile('{actor}',jsonb_build_object('name','Admin concurrency QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb));
      insert into private.memberships(user_id) values('{actor}');
      insert into private.admin_roles(user_id,role) values('{actor}','admin');
      insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values('{profile}','managed','Managed concurrency QA','','Test',array['Design']);
      insert into private.managed_profile_grants(user_id,profile_id,can_manage,can_reply) values('{actor}','{profile}',true,true);
    """)
    authorize = f"select private.require_managed_profile('{actor}','{profile}',true);"
    disable = f"select private.require_managed_profile('{actor}','{profile}',false); update public.profiles set disabled_at=clock_timestamp() where id='{profile}';"
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            disabling = pool.submit(sql, "begin; set local application_name='paul-admin-race';" + disable + 'select pg_sleep(1); commit;')
            wait_barrier()
            replying = pool.submit(sql, authorize, False)
            time.sleep(.1)
            assert not replying.done(), 'Reply authorization must wait for the disable commit'
            disabling.result()
            denied = replying.result()
            assert denied.returncode != 0 and 'managed_profile_forbidden' in denied.stderr
        print('PASS disable commit blocks and then denies concurrent reply authorization')
        sql(f"update public.profiles set disabled_at=null where id='{profile}';")
        with ThreadPoolExecutor(max_workers=2) as pool:
            replying = pool.submit(sql, "begin; set local application_name='paul-admin-race';" + authorize + 'select pg_sleep(1); commit;')
            wait_barrier()
            disabling = pool.submit(sql, disable)
            time.sleep(.1)
            assert not disabling.done(), 'Disable must wait for an already authorized operation'
            replying.result()
            disabling.result()
        assert 'managed_profile_forbidden' in sql(authorize, False).stderr
        print('PASS authorized operation serializes before disable, subsequent authorization is denied')
        sql(f"update public.profiles set disabled_at=null where id='{profile}';")
        with ThreadPoolExecutor(max_workers=2) as pool:
            replying = pool.submit(sql, "begin; set local application_name='paul-admin-race';" + authorize + 'select pg_sleep(1); commit;')
            wait_barrier()
            revoking = pool.submit(sql, f"update private.managed_profile_grants set revoked_at=clock_timestamp() where user_id='{actor}' and profile_id='{profile}';")
            time.sleep(.1)
            assert not revoking.done(), 'Grant revocation must serialize with the authorized operation'
            replying.result()
            revoking.result()
        assert 'managed_profile_forbidden' in sql(authorize, False).stderr
        print('PASS grant revocation serializes and immediately rejects subsequent authorization')
    finally:
        sql(f"""delete from private.managed_profile_grants where user_id='{actor}';
          delete from public.profiles where id='{profile}';
          delete from private.admin_roles where user_id='{actor}';
          delete from private.memberships where user_id='{actor}';
          delete from public.profiles where id='{actor}';
          delete from auth.users where id='{actor}';""")


if __name__ == '__main__':
    main()
