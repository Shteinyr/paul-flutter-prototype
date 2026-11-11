"""Transactional Community outbox and cancellation races in an isolated Paul DB."""
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
    people = [f'48900000-0000-4000-8000-{n:012d}' for n in range(1, 13)]
    author, recipient = people[:2]
    author_session = '48910000-0000-4000-8000-000000000001'
    recipient_session = '48910000-0000-4000-8000-000000000002'
    binding = '48920000-0000-4000-8000-000000000002'
    ids = ','.join("'" + person + "'" for person in people)

    def sql(statement, check=True):
        return subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input="set statement_timeout='10s';" + statement, text=True, capture_output=True, check=check,
        )

    def value(statement):
        return sql(statement).stdout.strip().splitlines()[-1]

    def create(operation):
        return f"select public.community_create('{author}','{author_session}','{operation}','Design','Community race QA');"

    def close(request):
        return f"select public.community_close('{author}','{author_session}','{uuid.uuid4()}','{request}');"

    def wait_barrier():
        for _ in range(80):
            if value("select count(*) from pg_stat_activity where application_name='paul-community-push-race' and wait_event='PgSleep';") != '0':
                return
            time.sleep(.025)
        raise AssertionError('Transaction did not reach the race barrier')

    sql(f"""insert into auth.users(id) values {','.join("('"+person+"')" for person in people)};
        select private.save_profile(id,jsonb_build_object('name','Community concurrency QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id in({ids});
        insert into private.memberships(user_id) select id from public.profiles where id in({ids});
        insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
            select id,'{author}',clock_timestamp() from public.profiles where id in({ids}) and id not in('{author}','{recipient}');
        insert into auth.sessions(id,user_id) values('{author_session}','{author}'),('{recipient_session}','{recipient}');
        select public.push_subscribe('{recipient}','{recipient_session}','{binding}','https://fcm.googleapis.com/fcm/send/community-race','B'||repeat('A',86),repeat('B',22));""")
    try:
        operation = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: json.loads(value(create(operation))), range(8)))
        requests = {result['request_id'] for result in results}
        assert len(requests) == 1
        request = requests.pop()
        assert value(f"select count(*) from private.notification_jobs where request_id='{request}';") == '1'
        with ThreadPoolExecutor(max_workers=8) as pool:
            deliveries = [claim for claims in pool.map(lambda _: json.loads(value('select public.push_claim(20);')), range(8)) for claim in claims]
        assert len(deliveries) == 1
        sql(close(request))
        print('PASS eight create retries and eight workers retain one request, one recipient job and one delivery', flush=True)

        request = json.loads(value(create(str(uuid.uuid4()))))['request_id']
        with ThreadPoolExecutor(max_workers=2) as pool:
            claiming = pool.submit(sql, "begin; set local application_name='paul-community-push-race'; select public.push_claim(20); select pg_sleep(1); commit;")
            wait_barrier()
            closing = pool.submit(sql, close(request))
            time.sleep(.1)
            assert not closing.done()
            claiming.result()
            closing.result()
        assert value(f"select count(*) from private.push_deliveries d join private.notification_jobs j on j.id=d.job_id where j.request_id='{request}' and d.status='cancelled';") == '1'
        assert value(f"select count(*) from public.community_requests where id='{request}';") == '0'
        print('PASS close waits for in-flight outbox expansion and cancels the newly committed delivery', flush=True)

        request = json.loads(value(create(str(uuid.uuid4()))))['request_id']
        delivery = json.loads(value('select public.push_claim(20);'))[0]
        prepare = f"select public.push_prepare('{delivery['delivery_id']}','{delivery['lease_token']}');"
        with ThreadPoolExecutor(max_workers=2) as pool:
            preparing = pool.submit(sql, "begin; set local application_name='paul-community-push-race';" + prepare + 'select pg_sleep(1); commit;')
            wait_barrier()
            closing = pool.submit(sql, close(request))
            time.sleep(.1)
            assert not closing.done()
            preparing.result()
            closing.result()
        assert value(f"select public.push_finish('{delivery['delivery_id']}','{delivery['lease_token']}','sent',201);") == 'f'
        route = json.loads(value(f"select public.push_resolve('{recipient}','{recipient_session}','{delivery['delivery_id']}','{binding}');"))
        assert route == {'kind': 'community', 'request_id': request, 'state': 'unavailable'}
        print('PASS close serializes after preparation, invalidates its lease and retains unavailable click resolution', flush=True)

        request = json.loads(value(create(str(uuid.uuid4()))))['request_id']
        sql(f"update public.community_requests set created_at=clock_timestamp()-interval '31 days',expires_at=clock_timestamp()-interval '1 second' where id='{request}';")
        with ThreadPoolExecutor(max_workers=8) as pool:
            expired = list(pool.map(lambda _: int(value('select public.community_expire(200);')), range(8)))
        assert sum(expired) == 1
        assert json.loads(value('select public.push_claim(20);')) == []
        assert value(f"select bool_and(push_expanded_at is not null) from private.notification_jobs where request_id='{request}';") == 't'
        print('PASS competing expiry workers physically remove once and suppress every pending broadcast', flush=True)
    finally:
        sql(f"""delete from private.push_deliveries where job_id in(select id from private.notification_jobs where recipient_user_id in({ids}));
            delete from private.notification_jobs where recipient_user_id in({ids});
            delete from private.push_subscriptions where user_id in({ids});
            delete from public.community_requests where author_profile_id in({ids});
            delete from private.community_operations where actor_profile_id in({ids});
            delete from private.invited_registrations where inviter_profile_id='{author}';
            delete from auth.sessions where user_id in({ids});
            delete from private.memberships where user_id in({ids});
            delete from public.profiles where id in({ids});
            delete from auth.users where id in({ids});""")


if __name__ == '__main__':
    main()
