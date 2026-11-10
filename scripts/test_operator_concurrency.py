"""Actual reply-as concurrency gates in an explicitly isolated Paul database."""
from concurrent.futures import ThreadPoolExecutor
import subprocess
import sys
import time

from test_chat_concurrency import run_sql


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-') or not sys.argv[2].startswith('paul_'):
        raise SystemExit('Pass the isolated Paul container and database names.')
    container = sys.argv[1]
    actor = '44200000-0000-4000-8000-000000000001'
    other = '44200000-0000-4000-8000-000000000002'
    peer = '44200000-0000-4000-8000-000000000003'
    managed = '44200000-0000-4000-8000-000000000004'

    def sql(statement):
        return run_sql(container, statement)

    def barrier():
        for _ in range(60):
            if sql("select count(*) from pg_stat_activity where application_name='paul-operator-race' and wait_event='PgSleep';") != '0':
                return
            time.sleep(.05)
        raise AssertionError('Reply transaction never reached its lock barrier')

    sql(f"""insert into auth.users(id) values('{actor}'),('{other}'),('{peer}');
      select private.save_profile(id,jsonb_build_object('name','Operator race QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id in ('{actor}','{other}','{peer}');
      insert into private.memberships(user_id) values('{actor}'),('{other}'),('{peer}');
      insert into private.admin_roles(user_id,role) values('{actor}','admin'),('{other}','admin');
      insert into public.profiles(id,profile_kind,name,occupation,summary,skills) values('{managed}','managed','Managed race QA','','Test',array['Design']);
      insert into private.managed_profile_grants(user_id,profile_id,can_manage,can_reply) values('{actor}','{managed}',true,true),('{other}','{managed}',false,true);
      insert into public.connections(user_low,user_high) values('{peer}','{managed}');""")
    conversation = sql(f"select public.chat_open('{peer}','{managed}')->>'id';")
    operation = '44200000-0000-4000-8000-000000000005'

    def send(user, op, text='Concurrent manual QA'):
        return f"select public.operator_send('{user}','{managed}','{conversation}','{op}','{text}');"

    def disable(op):
        return f"select public.admin_set_profile_enabled('{actor}','{managed}',false,'{op}',(select updated_at from public.profiles where id='{managed}'));"

    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: sql(send(actor, operation)), range(8)))
        assert sql(f"select count(*) from public.messages where conversation_id='{conversation}';") == '1'
        assert sql(f"select count(*) from private.admin_audit where actor_user_id='{actor}' and action='reply_as';") == '1'
        assert sql(f"select count(*) from private.notification_jobs where conversation_id='{conversation}';") == '1'
        print('PASS eight concurrent operator retries commit one message, audit and outbox')
        sql(send(other, operation))
        assert sql(f"select count(distinct actor_user_id) from public.messages where conversation_id='{conversation}' and client_message_id='{operation}';") == '2'
        print('PASS operators sharing a sender retain independent actor-scoped operation identities')
        with ThreadPoolExecutor(max_workers=8) as pool:
            jobs = []
            for index in range(8):
                op = f'44200000-0000-4000-8000-{100 + index:012d}'
                statement = send(other, op) if index % 2 else f"select public.chat_send('{peer}','{conversation}','{op}','Concurrent incoming QA');"
                jobs.append(pool.submit(sql, statement))
            for job in jobs:
                job.result()
        assert sql(f"select count(*)=max(seq) and count(*)=10 from public.messages where conversation_id='{conversation}';") == 't'
        assert sql(f"select count(*) from private.notification_jobs where conversation_id='{conversation}';") == '10'
        print('PASS concurrent incoming and operator replies preserve sequence and transactional outbox')
        with ThreadPoolExecutor(max_workers=2) as pool:
            disabling = pool.submit(sql, "begin; set local application_name='paul-operator-race';" + disable('44200000-0000-4000-8000-000000000200') + 'select pg_sleep(1); commit;')
            barrier()
            reply = pool.submit(sql, send(actor, '44200000-0000-4000-8000-000000000201'))
            time.sleep(.1)
            assert not reply.done()
            disabling.result()
            try:
                reply.result()
                raise AssertionError('Disabled reply committed')
            except subprocess.CalledProcessError as error:
                assert 'managed_profile_forbidden' in error.stderr
        assert sql(f"select count(*) from public.messages where conversation_id='{conversation}';") == '10'
        print('PASS disable commit denies concurrent reply without message or audit')
        sql(f"select public.admin_set_profile_enabled('{actor}','{managed}',true,'44200000-0000-4000-8000-000000000202',(select updated_at from public.profiles where id='{managed}'));")
        with ThreadPoolExecutor(max_workers=2) as pool:
            reply = pool.submit(sql, "begin; set local application_name='paul-operator-race';" + send(actor, '44200000-0000-4000-8000-000000000203') + 'select pg_sleep(1); commit;')
            barrier()
            disabling = pool.submit(sql, disable('44200000-0000-4000-8000-000000000204'))
            time.sleep(.1)
            assert not disabling.done()
            reply.result()
            disabling.result()
        assert sql(f"select count(*) from public.messages where conversation_id='{conversation}';") == '11'
        print('PASS authorized reply commits before a concurrent disable')
    finally:
        sql(f"""delete from private.admin_audit where actor_user_id in ('{actor}','{other}');
          delete from private.notification_jobs where conversation_id='{conversation}';
          delete from public.messages where conversation_id='{conversation}';
          delete from public.conversation_members where conversation_id='{conversation}';
          delete from public.conversations where id='{conversation}';
          delete from public.connections where user_low='{peer}' and user_high='{managed}';
          delete from private.managed_profile_grants where profile_id='{managed}';
          delete from private.admin_roles where user_id in ('{actor}','{other}');
          delete from private.memberships where user_id in ('{actor}','{other}','{peer}');
          delete from public.profiles where id in ('{actor}','{other}','{peer}','{managed}');
          delete from auth.users where id in ('{actor}','{other}','{peer}');
          delete from realtime.messages where topic in ('admin:user:{actor}','admin:user:{other}','chat:user:{peer}','chat:user:{managed}');""")


if __name__ == '__main__':
    main()
