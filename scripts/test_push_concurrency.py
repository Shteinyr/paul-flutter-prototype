"""Subscription quota and delivery fencing in an isolated Paul push database."""
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import uuid


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-') or not sys.argv[2].startswith('paul_push'):
        raise SystemExit('Pass the isolated Paul container and paul_push database.')
    container, database = sys.argv[1:]
    sender = '78400000-0000-4000-8000-000000000001'
    recipient = '78400000-0000-4000-8000-000000000002'
    session = '78500000-0000-4000-8000-000000000002'

    def sql(statement, check=True):
        return subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input=statement, text=True, capture_output=True, check=check,
        )

    def subscribe(number, endpoint=None):
        binding = str(uuid.uuid4())
        endpoint = endpoint or 'https://fcm.googleapis.com/fcm/send/race-' + str(number)
        return sql(f"set role service_role; select public.push_subscribe('{recipient}','{session}','{binding}','{endpoint}','B'||repeat('A',86),repeat('B',22));", False)

    sql(f"""insert into auth.users values('{sender}'),('{recipient}');
        select private.save_profile(id,jsonb_build_object('name','Push concurrency QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id in ('{sender}','{recipient}');
        insert into private.memberships(user_id) values('{sender}'),('{recipient}');
        insert into auth.sessions(id,user_id) values('{session}','{recipient}');
        insert into public.connections(user_low,user_high) values('{sender}','{recipient}');
    """)
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda n: subscribe(n, 'https://fcm.googleapis.com/fcm/send/canonical-race'), range(8)))
        assert all(result.returncode == 0 for result in results)
        canonical = [json.loads(result.stdout.splitlines()[-1])['binding_id'] for result in results]
        assert len(set(canonical)) == 1
        assert sql(f"select count(*) from private.push_subscriptions where user_id='{recipient}';").stdout.strip() == '1'
        print('PASS eight parallel tabs share one binding and original cutoff')

        for number in range(14):
            assert subscribe(number).returncode == 0
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(subscribe, [100, 101]))
        assert sum(result.returncode == 0 for result in results) == 1
        assert all(result.returncode == 0 or 'rate_limited' in result.stderr for result in results)
        assert sql(f"select count(*) from private.push_subscriptions where user_id='{recipient}' and disabled_at is null;").stdout.strip() == '16'
        print('PASS different endpoint registrations serialize at the active-device cap')

        sql(f"update private.push_subscriptions set disabled_at=clock_timestamp() where user_id='{recipient}' and binding_id<>'{canonical[0]}';")
        conversation = sql(f"select public.chat_open('{sender}','{recipient}')->>'id';").stdout.strip()
        sql(f"select public.chat_send('{sender}','{conversation}','{uuid.uuid4()}','Private push concurrency text');")

        def claim(_):
            result = sql('set role service_role; select public.push_claim(1);')
            return json.loads(result.stdout.splitlines()[-1])

        with ThreadPoolExecutor(max_workers=8) as pool:
            claims = [claim for batch in pool.map(claim, range(8)) for claim in batch]
        assert len(claims) == 1
        first = claims[0]
        assert sql(f"select count(*) from private.push_deliveries where binding_id='{canonical[0]}';").stdout.strip() == '1'
        print('PASS eight workers claim a job once and retain one job/binding delivery')

        sql(f"update private.push_deliveries set lease_until=clock_timestamp()-interval '1 second' where id='{first['delivery_id']}';")
        with ThreadPoolExecutor(max_workers=8) as pool:
            claims = [claim for batch in pool.map(claim, range(8)) for claim in batch]
        assert len(claims) == 1 and claims[0]['delivery_id'] == first['delivery_id']
        second = claims[0]
        assert second['lease_token'] != first['lease_token']
        assert sql(f"select public.push_prepare('{first['delivery_id']}','{first['lease_token']}') is null;").stdout.strip() == 't'
        assert sql(f"select public.push_finish('{first['delivery_id']}','{first['lease_token']}','sent',201);").stdout.strip() == 'f'
        assert sql(f"select public.push_finish('{second['delivery_id']}','{second['lease_token']}','sent',201);").stdout.strip() == 't'
        print('PASS expired lease recovers once and fences the stale worker')

        sql(f"select public.chat_send('{sender}','{conversation}','{uuid.uuid4()}','Logout cancellation');")
        pending = claim(0)[0]
        sql(f"delete from auth.sessions where id='{session}';")
        assert sql(f"set role service_role; select public.push_prepare('{pending['delivery_id']}','{pending['lease_token']}') is null;").stdout.splitlines()[-1] == 't'
        print('PASS server logout cancels a previously claimed send before endpoint disclosure')
    finally:
        sql(f"""delete from private.push_deliveries where binding_id in(select binding_id from private.push_subscriptions where user_id='{recipient}');
            delete from private.push_subscriptions where user_id='{recipient}';
            delete from private.notification_jobs where conversation_id in(select id from public.conversations where user_low='{sender}');
            delete from public.messages where conversation_id in(select id from public.conversations where user_low='{sender}');
            delete from public.conversation_members where conversation_id in(select id from public.conversations where user_low='{sender}');
            delete from public.conversations where user_low='{sender}';
            delete from public.connections where user_low='{sender}';
            delete from auth.sessions where user_id in('{sender}','{recipient}');
            delete from private.memberships where user_id in('{sender}','{recipient}');
            delete from public.profiles where id in('{sender}','{recipient}');
            delete from auth.users where id in('{sender}','{recipient}');""")


if __name__ == '__main__':
    main()
