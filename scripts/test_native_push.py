"""Native push gates in one disposable PostgreSQL container; no ports or volumes.

Uses this checkout's admission migration by default. An explicit override permits
read-only integration with the coordinator's migration; hosted data is never used.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--admission-migration', type=Path,
                        default=root / 'supabase/migrations/20261115045020_invite_session_admission.sql')
    args = parser.parse_args()
    admission = args.admission_migration.read_text()
    if args.admission_migration.name != '20261115045020_invite_session_admission.sql':
        raise SystemExit('Supply the reviewed session-admission migration.')
    image = 'postgres:17-alpine3.23'
    subprocess.run(['docker', 'image', 'inspect', image], check=True, stdout=subprocess.DEVNULL)
    container = f'paul-native-push15-{os.getpid()}'
    subprocess.run(['docker', 'run', '-d', '--rm', '--name', container, '--network', 'none',
                    '--memory', '256m', '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image], check=True, stdout=subprocess.DEVNULL)

    def sql(statement, check=True):
        result = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
                                input=statement, text=True, capture_output=True)
        if check and result.returncode:
            raise RuntimeError(result.stderr)
        return result
    def value(statement):
        lines = sql(statement).stdout.strip().splitlines()
        return lines[-1] if lines else ''
    def uid(n):
        return f'15000000-0000-4000-8000-{n:012d}'
    def session(n):
        return f'15100000-0000-4000-8000-{n:012d}'
    def subscribe(user, sid, binding, token):
        digest = hashlib.sha256(token.encode()).hexdigest()
        return sql(f"set role service_role; select public.native_push_subscribe('{user}','{sid}','{binding}','{token}','{digest}','ios');", False)

    try:
        for _ in range(60):
            if subprocess.run(['docker','exec',container,'sh','-c','test "$(cat /proc/1/comm)" = postgres && pg_isready -U postgres'], capture_output=True).returncode == 0:
                break
            time.sleep(.2)
        else:
            raise RuntimeError('Isolated PostgreSQL did not become ready.')
        sql((root / 'supabase/tests/bootstrap.sql').read_text())
        skipped = {'20261110154303_schedule_web_push_worker.sql', '20261111050427_schedule_maintenance_worker.sql'}
        for migration in sorted((root / 'supabase/migrations').glob('*.sql')):
            if migration.name in skipped or migration.name >= '20261115':
                continue
            sql(migration.read_text())
        sql((root / 'supabase/tests/session_admission_upgrade_setup.sql').read_text())
        sql(admission)
        sql((root / 'supabase/migrations/20261115063818_native_push_transport.sql').read_text())
        print('PASS schema against admission SHA256 ' + hashlib.sha256(admission.encode()).hexdigest(), flush=True)
        sql((root / 'supabase/tests/session_admission.sql').read_text())
        print('PASS existing admission, RLS, TTL, retry and referral regressions', flush=True)
        sql((root / 'supabase/tests/session_admission_upgrade.sql').read_text())
        print('PASS real legacy snapshot receipts and invite-bound Storage permit regressions', flush=True)
        sql(f"""insert into auth.users(id) select ('15000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,12)n;
          select private.save_profile(id,jsonb_build_object('name','Native QA','occupation','','summary','Test',
            'skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id::text like '15000000-0000-4000-8000-%';
          insert into private.memberships(user_id) select id from auth.users where id::text like '15000000-0000-4000-8000-%';
          insert into auth.sessions(id,user_id) values('{session(1)}','{uid(1)}'),('{session(2)}','{uid(2)}'),('{session(3)}','{uid(1)}');
          insert into private.session_admissions(user_id,session_id,source) values('{uid(1)}','{session(1)}','existing_session'),('{uid(2)}','{session(2)}','existing_session');
          insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
            select id,'{uid(2)}',clock_timestamp() from auth.users where id::text like '15000000-0000-4000-8000-%' and id not in('{uid(1)}','{uid(2)}');
          insert into public.connections(user_low,user_high) values('{uid(1)}','{uid(2)}');""")
        binding = str(uuid.uuid4())
        token = 'native-device-capability-1234567890'
        denied = subscribe(uid(1),session(3),str(uuid.uuid4()),token)
        assert denied.returncode and 'session_admission_required' in denied.stderr
        result = subscribe(uid(1),session(1),binding,token)
        assert result.returncode == 0, result.stderr
        assert value("select has_function_privilege('authenticated','public.native_push_subscribe(uuid,uuid,uuid,text,text,text)','execute');") == 'f'
        assert value("select relrowsecurity from pg_class where oid='private.native_push_bindings'::regclass;") == 't'
        print('PASS live Auth without admission denied; client RPC/table privileges closed', flush=True)
        with ThreadPoolExecutor(max_workers=8) as pool:
            responses = list(pool.map(lambda _: subscribe(uid(1),session(1),str(uuid.uuid4()),token), range(8)))
        assert all(r.returncode == 0 for r in responses)
        assert {json.loads(r.stdout.splitlines()[-1])['binding_id'] for r in responses} == {binding}
        assert value("select count(*) from private.native_push_bindings where disabled_at is null;") == '1'
        assert subscribe(uid(2),session(2),binding,token).returncode != 0
        print('PASS eight native registrations share canonical binding; another owner cannot reuse its ID', flush=True)
        conversation = value(f"select public.chat_open('{uid(2)}','{uid(1)}')->>'id';")
        sql(f"select public.chat_send('{uid(2)}','{conversation}','{uuid.uuid4()}','Private message stays outside push');")
        claims = json.loads(value('select public.native_push_claim(4);'))
        assert len(claims) == 1, claims
        first = claims[0]
        def prepare(claim):
            return json.loads(value(f"select public.native_push_prepare('{claim['delivery_id']}','{claim['lease_token']}');") or 'null')
        prepared = prepare(first)
        assert prepared['payload']['kind'] == 'message_created'
        assert 'Private message' not in json.dumps(prepared)
        assert subscribe(uid(1),session(1),binding,'rotated-native-capability-1234567890').returncode == 0
        assert prepare(first) is None
        second = json.loads(value('select public.native_push_claim(4);'))[0]
        assert second['delivery_id'] == first['delivery_id']
        assert second['lease_token'] != first['lease_token']
        assert prepare(second)['token'].startswith('rotated-')
        assert value(f"select public.native_push_finish('{first['delivery_id']}','{first['lease_token']}','sent',200);") == 'f'
        sql(f"update private.session_admissions set revoked_at=clock_timestamp() where session_id='{session(1)}';")
        assert value(f"select public.native_push_finish('{second['delivery_id']}','{second['lease_token']}','sent',200);") == 'f'
        assert value(f"select status from private.native_push_deliveries where id='{second['delivery_id']}';") == 'cancelled'
        sql(f"update private.session_admissions set revoked_at=null where session_id='{session(1)}';")
        print('PASS token rotation fences old leases; revoked admission cancels prepared delivery', flush=True)
        request = json.loads(value(f"select public.community_create('{uid(2)}','{session(2)}','{uuid.uuid4()}','Design','Need a designer');"))['request_id']
        assert value(f"select count(*) from private.notification_jobs where request_id='{request}' and recipient_user_id='{uid(1)}';") == '1'
        assert value('select count(*) from private.push_subscriptions;') == '0'
        delivery = json.loads(value('select public.native_push_claim(4);'))[0]
        assert prepare(delivery)['payload']['kind'] == 'community_created'
        sql(f"select public.community_close('{uid(2)}','{session(2)}','{uuid.uuid4()}','{request}');")
        assert prepare(delivery) is None
        route = json.loads(value(f"select public.native_push_resolve('{uid(1)}','{session(1)}','{binding}','{delivery['delivery_id']}');"))
        assert route == {'kind':'community','request_id':request,'state':'unavailable'}
        print('PASS native-only Hiring audience; close cancels queued send and resolves unavailable tap', flush=True)
        sql(f"select public.chat_send('{uid(2)}','{conversation}','{uuid.uuid4()}','Retry gate');")
        for attempt in range(1, 6):
            retried = json.loads(value('select public.native_push_claim(4);'))
            assert len(retried) == 1
            retried = retried[0]
            assert prepare(retried) is not None
            assert value(f"select public.native_push_finish('{retried['delivery_id']}','{retried['lease_token']}','retry',503,30);") == 't'
            assert value(f"select attempts from private.native_push_deliveries where id='{retried['delivery_id']}';") == str(attempt)
            sql(f"update private.native_push_deliveries set next_attempt_at=clock_timestamp()-interval '1 second' where id='{retried['delivery_id']}';")
        assert value(f"select status from private.native_push_deliveries where id='{retried['delivery_id']}';") == 'failed'
        assert json.loads(value('select public.native_push_claim(4);')) == []
        sql(f"select public.chat_send('{uid(2)}','{conversation}','{uuid.uuid4()}','Unregistered gate');")
        invalid = json.loads(value('select public.native_push_claim(4);'))[0]
        assert prepare(invalid) is not None
        assert value(f"select public.native_push_finish('{invalid['delivery_id']}','{invalid['lease_token']}','invalid',404);") == 't'
        assert value(f"select disabled_at is not null from private.native_push_bindings where binding_id='{binding}';") == 't'
        assert subscribe(uid(1),session(1),binding,'rotated-native-capability-1234567890').returncode == 0
        print('PASS retries stop after five attempts; unregistered device is retired and can explicitly re-register', flush=True)
        sql(f"select public.member_delete_account('{uid(1)}','{session(1)}','{uid(1)}','{uuid.uuid4()}','{'a' * 64}');")
        assert value(f"select count(*) from private.native_push_bindings where user_id='{uid(1)}';") == '0'
        assert value('select count(*) from private.native_push_deliveries;') == '0'
        assert value(f"select count(*) from public.messages where conversation_id='{conversation}';") == '3'
        print('PASS account deletion purges native capabilities and delivery metadata; conversation history retained', flush=True)
    finally:
        subprocess.run(['docker','rm','-f',container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        if subprocess.run(['docker','inspect',container], capture_output=True).returncode == 0:
            raise RuntimeError('Own native-push test container was not removed.')
        print('PASS own container removed; no volume or host listener created', flush=True)

if __name__ == '__main__':
    main()
