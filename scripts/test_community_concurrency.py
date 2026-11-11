"""Community replay and deletion races in an explicitly isolated Paul database.

Requires the real Community, deletion and notification integration migrations. This gate never
replaces its hooks with stubs.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import subprocess
import sys
import time
import uuid


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-') or not sys.argv[2].startswith('paul_'):
        raise SystemExit('Pass the isolated Paul container and Paul database names.')
    container, database = sys.argv[1:]
    actor, session = str(uuid.uuid4()), str(uuid.uuid4())
    second_actor, second_session = str(uuid.uuid4()), str(uuid.uuid4())
    invitees = [str(uuid.uuid4()) for _ in range(10)]
    second_invitees = [str(uuid.uuid4()) for _ in range(10)]
    authors = f"'{actor}','{second_actor}'"
    all_users = ','.join(f"'{value}'" for value in [actor, second_actor, *invitees, *second_invitees])

    def sql(statement, check=True):
        result = subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database,
             '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input=statement, text=True, capture_output=True, check=False,
        )
        if check and result.returncode != 0:
            raise RuntimeError(result.stderr.strip())
        return result

    def data(statement):
        return json.loads(sql(statement).stdout.strip())

    def create(operation):
        return f"select public.community_create('{actor}','{session}','{operation}','Design','Concurrency request');"

    def close(operation, request):
        return f"select public.community_close('{actor}','{session}','{operation}','{request}');"

    def barrier():
        for _ in range(60):
            count = sql("select count(*) from pg_stat_activity where application_name='paul-community-race' and wait_event='PgSleep';").stdout.strip()
            if count != '0':
                return
            time.sleep(.05)
        raise AssertionError('Community transaction did not reach its lock barrier')

    hooks = sql("select to_regprocedure('private.enqueue_community_notifications(uuid)') is not null and to_regprocedure('private.cancel_community_notifications(uuid)') is not null;").stdout.strip()
    assert hooks == 't', 'Apply the actual Community outbox migration before this gate'
    sql(f"""
      begin;
      insert into auth.users(id) select unnest(array[{all_users}]::uuid[]);
      select private.save_profile(id,jsonb_build_object('name','Community concurrency QA',
        'occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id in ({all_users});
      insert into private.memberships(user_id) values('{actor}'),('{second_actor}');
      insert into auth.sessions(id,user_id) values('{session}','{actor}'),('{second_session}','{second_actor}');
      insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
        select unnest(array[{','.join(f"'{value}'" for value in invitees)}]::uuid[]),'{actor}',clock_timestamp();
      insert into private.invited_registrations(invitee_profile_id,inviter_profile_id,registered_at)
        select unnest(array[{','.join(f"'{value}'" for value in second_invitees)}]::uuid[]),'{second_actor}',clock_timestamp();
      commit;
    """)
    try:
        operation = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(pool.map(lambda _: data(create(operation)), range(8)))
        request = replies[0]['request_id']
        assert len({item['request_id'] for item in replies}) == 1
        assert sum(not item['replayed'] for item in replies) == 1
        assert sql(f"select count(*)=1 from public.community_requests where author_profile_id='{actor}';").stdout.strip() == 't'
        print('PASS concurrent publication retries persist one request and one receipt')

        close_operation = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=8) as pool:
            replies = list(pool.map(lambda _: data(close(close_operation, request)), range(8)))
        assert all(item['state'] == 'unavailable' for item in replies)
        assert sum(not item['replayed'] for item in replies) == 1
        assert data(create(operation))['state'] == 'unavailable'
        print('PASS concurrent close retries are idempotent and create replay cannot resurrect text')

        request = data(create(str(uuid.uuid4())))['request_id']
        sql(f"update public.community_requests set created_at=clock_timestamp()-interval '31 days',expires_at=clock_timestamp()-interval '1 second' where id='{request}';")
        with ThreadPoolExecutor(max_workers=2) as pool:
            expiring = pool.submit(sql, 'select public.community_expire(200);')
            closing = pool.submit(sql, close(str(uuid.uuid4()), request))
            expiring.result(timeout=15)
            closing.result(timeout=15)
        assert sql(f"select count(*)=0 from public.community_requests where id='{request}';").stdout.strip() == 't'
        print('PASS expiry and owner close race physically remove the request')

        deletion_operation = str(uuid.uuid4())
        receipt_hash = uuid.uuid4().hex + uuid.uuid4().hex
        deleting_account = f"select public.member_delete_account('{actor}','{session}','{actor}','{deletion_operation}','{receipt_hash}');"
        with ThreadPoolExecutor(max_workers=2) as pool:
            deleting = pool.submit(sql, "begin; set local application_name='paul-community-race';" + deleting_account + 'select pg_sleep(1); commit;')
            barrier()
            publishing = pool.submit(sql, create(str(uuid.uuid4())), False)
            time.sleep(.1)
            assert not publishing.done(), 'Publish must wait for the deletion profile lock'
            deleting.result(timeout=15)
            denied = publishing.result(timeout=15)
        assert denied.returncode != 0 and 'session_revoked' in denied.stderr
        assert sql(f"select count(*)=0 from public.community_requests where author_profile_id='{actor}';").stdout.strip() == 't'
        print('PASS real account deletion serializes before publication and revokes the late session')

        actor, session = second_actor, second_session
        deletion_operation = str(uuid.uuid4())
        receipt_hash = uuid.uuid4().hex + uuid.uuid4().hex
        deleting_account = f"select public.member_delete_account('{actor}','{session}','{actor}','{deletion_operation}','{receipt_hash}');"
        with ThreadPoolExecutor(max_workers=2) as pool:
            publishing = pool.submit(sql, "begin; set local application_name='paul-community-race';" + create(str(uuid.uuid4())) + 'select pg_sleep(1); commit;')
            barrier()
            deleting = pool.submit(sql, deleting_account)
            time.sleep(.1)
            assert not deleting.done(), 'Deletion must wait for an already authorized publication'
            publishing.result(timeout=15)
            deleting.result(timeout=15)
        assert sql(f"select count(*)=0 from public.community_requests where author_profile_id='{actor}';").stdout.strip() == 't'
        print('PASS publication commits before author cleanup and leaves no surviving request')
    finally:
        sql(f"select private.community_remove_for_author(id) from public.profiles where id in ({authors});")
        # Remove only this gate's generated fixtures from the isolated database.
        sql(f"""
          begin;
          delete from private.notification_jobs where request_id in(select request_id from private.community_operations where actor_profile_id in ({authors}));
          delete from private.admin_audit where actor_user_id in ({all_users}) or profile_id in ({all_users});
          delete from private.account_deletions where target_profile_id in ({all_users});
          delete from private.community_operations where actor_profile_id in ({authors});
          delete from private.invited_registrations where inviter_profile_id in ({authors});
          delete from private.memberships where user_id in ({all_users});
          delete from auth.sessions where user_id in ({all_users});
          delete from public.profiles where id in ({all_users});
          delete from auth.users where id in ({all_users});
          commit;
        """)


if __name__ == '__main__':
    main()
