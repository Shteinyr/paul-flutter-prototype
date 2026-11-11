"""Deletion/Storage/registration race gates in an isolated Paul MVP database."""
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
    people = [f'72900000-0000-4000-8000-{n:012d}' for n in range(1, 7)]
    sessions = [f'72910000-0000-4000-8000-{n:012d}' for n in range(1, 7)]
    commands = [str(uuid.uuid4()) for _ in people]
    member, blocked, uploading, inviter, newcomer, receiver = people
    draft = json.dumps({'name': 'Deletion race QA', 'occupation': '', 'summary': 'Test', 'skills': ['Design'], 'searching_skills': []})

    def sql(statement, check=True):
        return subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input="set statement_timeout='10s';" + statement, text=True, capture_output=True, check=check,
        )

    def value(statement):
        return sql(statement).stdout.strip().splitlines()[-1]

    def deletion(index):
        return f"select public.member_delete_account('{people[index]}','{sessions[index]}','{people[index]}','{commands[index]}',repeat('a',64));"

    def wait_barrier():
        for _ in range(80):
            if value("select count(*) from pg_stat_activity where application_name='paul-delete-race' and wait_event='PgSleep';") != '0':
                return
            time.sleep(.025)
        raise AssertionError('Transaction did not reach the race barrier')

    ids = ','.join("'" + person + "'" for person in people)
    sql(f"""insert into auth.users(id) values {','.join("('"+person+"')" for person in people)};
        select private.save_profile(id,'{draft}'::jsonb) from auth.users where id in({ids}) and id<>'{newcomer}';
        insert into private.memberships(user_id) select id from public.profiles where id in({ids});
        insert into auth.sessions(id,user_id) values {','.join("('"+session+"','"+person+"')" for session,person in zip(sessions,people))};
        select public.issue_invitation('{receiver}',repeat('b',64),repeat('c',64));
        insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','{newcomer}/'||repeat('d',64)||'.png','{newcomer}');""")
    try:
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(lambda _: sql(deletion(0)), range(8)))
        assert all(json.loads(result.stdout.splitlines()[-1])['operation_id'] == commands[0] for result in results)
        assert value(f"select count(*) from private.account_deletions where target_profile_id='{member}';") == '1'
        assert value(f"select count(*) from private.admin_audit where actor_user_id='{member}' and action='account_delete';") == '1'
        print('PASS eight same-operation deletions commit one durable job and one audit record', flush=True)

        upload = f"insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','{blocked}/'||repeat('e',64)||'.png','{blocked}');"
        redeem = f"select public.redeem_invitation('{blocked}',repeat('b',64),false,'{{}}'::jsonb);"
        with ThreadPoolExecutor(max_workers=3) as pool:
            removing = pool.submit(sql, "begin; set local application_name='paul-delete-race';" + deletion(1) + 'select pg_sleep(1); commit;')
            wait_barrier()
            pending_upload = pool.submit(sql, upload, False)
            pending_redeem = pool.submit(sql, redeem, False)
            time.sleep(.1)
            assert not pending_upload.done() and not pending_redeem.done()
            removing.result()
            assert 'profile_unavailable' in pending_upload.result().stderr
            assert 'account_deleted' in pending_redeem.result().stderr
        assert value(f"select count(*) from private.memberships where user_id='{blocked}';") == '0'
        assert value(f"select count(*) from storage.objects where owner_id='{blocked}';") == '0'
        print('PASS committed deletion denies waiting late Storage upload and invitation redemption', flush=True)

        upload = f"insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','{uploading}/'||repeat('f',64)||'.png','{uploading}');"
        with ThreadPoolExecutor(max_workers=2) as pool:
            pending_upload = pool.submit(sql, "begin; set local application_name='paul-delete-race';" + upload + 'select pg_sleep(1); commit;')
            wait_barrier()
            removing = pool.submit(sql, deletion(2))
            time.sleep(.1)
            assert not removing.done()
            pending_upload.result()
            removing.result()
        lease = json.loads(value(f"select public.account_cleanup_claim('{commands[2]}',1);"))[0]['lease_token']
        prepared = json.loads(value(f"select public.account_cleanup_prepare('{commands[2]}','{lease}');"))
        assert prepared['objects'] == [{'bucket': 'avatars', 'name': uploading + '/' + 'f' * 64 + '.png'}]
        print('PASS in-flight upload commits before deletion and its file remains visible to cleanup', flush=True)

        sql(f"""select public.issue_invitation('{inviter}',repeat('1',64),repeat('2',64));
            create function public.deletion_race_barrier() returns trigger language plpgsql as $$
            begin if new.user_id='{newcomer}'::uuid then perform pg_sleep(1); end if; return new; end; $$;
            create trigger deletion_race_barrier before insert on private.memberships for each row execute function public.deletion_race_barrier();""")
        new_draft = json.loads(draft)
        new_draft['avatar_path'] = newcomer + '/' + 'd' * 64 + '.png'
        with ThreadPoolExecutor(max_workers=2) as pool:
            registering = pool.submit(sql, "set application_name='paul-delete-race';" + f"select public.redeem_invitation('{newcomer}',repeat('1',64),false,'{json.dumps(new_draft)}'::jsonb);")
            wait_barrier()
            removing = pool.submit(sql, deletion(3))
            time.sleep(.1)
            assert not removing.done()
            registering.result()
            removing.result()
        assert value(f"select private.invited_registration_count('{inviter}');") == '1'
        assert value(f"select count(*) from private.memberships where user_id='{newcomer}';") == '1'
        print('PASS registration serializes before inviter deletion without deadlock and preserves its completed credit', flush=True)

        with ThreadPoolExecutor(max_workers=8) as pool:
            claims = list(pool.map(lambda _: json.loads(value(f"select public.account_cleanup_claim('{commands[0]}',1);")), range(8)))
        leases = [claim[0]['lease_token'] for claim in claims if claim]
        assert len(leases) == 1
        sql(f"update private.account_deletions set lease_until=clock_timestamp()-interval '1 second' where operation_id='{commands[0]}';")
        with ThreadPoolExecutor(max_workers=2) as pool:
            reclaim = pool.submit(value, f"select public.account_cleanup_claim('{commands[0]}',1);")
            stale_finish = pool.submit(value, f"select public.account_cleanup_finish('{commands[0]}','{leases[0]}',false,'auth_unavailable') is null;")
            new_lease = json.loads(reclaim.result())[0]['lease_token']
            assert stale_finish.result() == 't'
        assert new_lease != leases[0]
        assert value(f"select lease_token from private.account_deletions where operation_id='{commands[0]}';") == new_lease
        assert value(f"select attempts from private.account_deletions where operation_id='{commands[0]}';") == '2'
        print('PASS concurrent cleanup claims have one owner and expired completion cannot alter its replacement', flush=True)
    finally:
        sql(f"""drop trigger if exists deletion_race_barrier on private.memberships;
            drop function if exists public.deletion_race_barrier();
            delete from private.admin_audit where actor_user_id in({ids});
            delete from private.account_deletions where target_profile_id in({ids});
            delete from private.invited_registrations where invitee_profile_id in({ids}) or inviter_profile_id in({ids});
            delete from public.connections where user_low in({ids}) or user_high in({ids});
            delete from private.invitations where issuer_id in({ids});
            delete from storage.objects where owner_id in({ids});
            delete from private.memberships where user_id in({ids});
            delete from auth.sessions where user_id in({ids});
            delete from public.profiles where id in({ids});
            delete from auth.users where id in({ids});
            delete from realtime.messages where topic in({','.join("'chat:user:"+p+"'" for p in people)});""")


if __name__ == '__main__':
    main()
