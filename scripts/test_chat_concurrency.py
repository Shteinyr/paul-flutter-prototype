"""Concurrency gate for the explicitly named, isolated local Postgres container."""

from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import time


def run_sql(container, statement):
    result = subprocess.run(
        ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
        input=statement, text=True, capture_output=True, check=True,
    )
    return result.stdout.strip()


def main():
    if len(sys.argv) != 2 or not sys.argv[1].startswith('paul-'):
        raise SystemExit('Pass the explicit isolated Paul test database container name.')
    container = sys.argv[1]
    a = '30000000-0000-4000-8000-000000000001'
    b = '30000000-0000-4000-8000-000000000002'
    client_id = '30000000-0000-4000-8000-000000000003'
    conversation = None
    run_sql(container, f"""
      insert into auth.users(id) values('{a}'),('{b}');
      select private.save_profile(id,jsonb_build_object('name','Concurrency QA','occupation','','summary','Test',
        'skills',array['Flutter'],'searching_skills','[]'::jsonb)) from auth.users where id in ('{a}','{b}');
      insert into private.memberships(user_id) values('{a}'),('{b}');
      insert into public.connections values('{a}','{b}',clock_timestamp());
    """)
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            opened = list(pool.map(lambda _: run_sql(container, f"select public.chat_open('{a}','{b}')->>'id';"), range(8)))
        assert len(set(opened)) == 1
        conversation = opened[0]
        print('PASS concurrent open creates exactly one canonical conversation')
        statement = f"select public.chat_send('{a}','{conversation}','{client_id}','Concurrent retry');"
        with ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(pool.map(lambda _: json.loads(run_sql(container, statement)), range(8)))
        assert sum(not reply['replayed'] for reply in replies) == 1
        assert len({reply['message']['id'] for reply in replies}) == 1
        print('PASS concurrent retries return the same persisted message')

        # A message holds the sequence lock before commit. A later send must
        # wait, so catch-up cannot advance beyond a not-yet-committed message.
        first_sql = f"""begin; select public.chat_send('{a}','{conversation}',
          '30000000-0000-4000-8000-000000000004','Earlier commit');
          select pg_sleep(2); commit;"""
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(run_sql, container, first_sql)
            for _ in range(30):
                waiting = run_sql(container, "select count(*) from pg_stat_activity where wait_event='PgSleep';")
                if int(waiting) > 0:
                    break
                time.sleep(0.05)
            else:
                raise AssertionError('Earlier transaction did not reach its commit barrier')
            second = pool.submit(run_sql, container, f"""select public.chat_send('{b}','{conversation}',
              '30000000-0000-4000-8000-000000000005','Later commit');""")
            first.result()
            later = json.loads(second.result())
        assert later['message']['seq'] == 3
        history = json.loads(run_sql(container, f"select public.chat_history('{a}','{conversation}',null,1,100);"))
        assert [message['seq'] for message in history['messages']] == [2, 3]
        print('PASS forward history includes both messages across delayed commit')
    finally:
        run_sql(container, f"""
          delete from public.messages where actor_user_id in ('{a}','{b}');
          delete from public.conversation_members where user_id in ('{a}','{b}');
          delete from public.conversations where user_low='{a}' and user_high='{b}';
          delete from public.connections where user_low='{a}' and user_high='{b}';
          delete from public.profiles where id in ('{a}','{b}');
          delete from auth.users where id in ('{a}','{b}');
        """)


if __name__ == '__main__':
    main()
