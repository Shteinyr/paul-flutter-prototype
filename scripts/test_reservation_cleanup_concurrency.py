"""Unfinished managed uploads versus creator deletion in an isolated Paul DB."""
from concurrent.futures import ThreadPoolExecutor
import json
import re
import subprocess
import sys
import time
import uuid


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-mvp') or not sys.argv[2].startswith('paul_mvp'):
        raise SystemExit('Pass the isolated paul-mvp container and paul_mvp database.')
    container, database = sys.argv[1:]
    actors = [f'74400000-0000-4000-8000-{n:012d}' for n in range(1, 6)]
    sessions = [f'74410000-0000-4000-8000-{n:012d}' for n in range(1, 6)]
    deletions = [str(uuid.uuid4()) for _ in actors]
    profiles = []

    def sql(statement, check=True):
        return subprocess.run(
            ['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'],
            input="set statement_timeout='10s';" + statement, text=True, capture_output=True, check=check,
        )

    def value(statement):
        return sql(statement).stdout.strip().splitlines()[-1]

    def prepare(index, operation=None):
        operation = operation or str(uuid.uuid4())
        target = value(f"select public.admin_prepare_create('{actors[index]}','{operation}');")
        profiles.append(target)
        return target, operation

    def upload(target):
        return f"insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','{target}/'||repeat('a',64)||'.png',null);"

    def remove(index):
        return f"select public.member_delete_account('{actors[index]}','{sessions[index]}','{actors[index]}','{deletions[index]}',repeat('a',64));"

    def wait_barrier():
        for _ in range(80):
            if value("select count(*) from pg_stat_activity where application_name='paul-reservation-race' and wait_event='PgSleep';") != '0':
                return
            time.sleep(.025)
        raise AssertionError('Transaction did not reach the race barrier')

    def cleanup_objects(index):
        claim = json.loads(value(f"select public.account_cleanup_claim('{deletions[index]}',1);"))[0]
        return json.loads(value(f"select public.account_cleanup_prepare('{deletions[index]}','{claim['lease_token']}');"))['objects']

    ids = ','.join("'" + actor + "'" for actor in actors)
    sql(f"""insert into auth.users(id) values {','.join("('"+actor+"')" for actor in actors)};
        select private.save_profile(id,jsonb_build_object('name','Reserved upload concurrency QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id in({ids});
        insert into private.memberships(user_id) select id from public.profiles where id in({ids});
        insert into auth.sessions(id,user_id) values {','.join("('"+session+"','"+actor+"')" for session,actor in zip(sessions,actors))};
        insert into private.admin_roles(user_id,role) select id,'admin' from public.profiles where id in({ids});""")
    try:
        target, _ = prepare(0)
        with ThreadPoolExecutor(max_workers=2) as pool:
            uploading = pool.submit(sql, "begin; set local application_name='paul-reservation-race';" + upload(target) + 'select pg_sleep(1); commit;')
            wait_barrier()
            removing = pool.submit(sql, remove(0))
            time.sleep(.1)
            assert not removing.done(), 'Creator deletion must wait for its already authorized reserved upload'
            uploading.result()
            removing.result()
        assert cleanup_objects(0) == [{'bucket': 'avatars', 'name': target + '/' + 'a' * 64 + '.png'}]
        print('PASS in-flight reserved upload commits first and its file is captured by creator cleanup', flush=True)

        target, _ = prepare(1)
        with ThreadPoolExecutor(max_workers=2) as pool:
            removing = pool.submit(sql, "begin; set local application_name='paul-reservation-race';" + remove(1) + 'select pg_sleep(1); commit;')
            wait_barrier()
            uploading = pool.submit(sql, upload(target), False)
            time.sleep(.1)
            assert not uploading.done(), 'Pending reserved upload must wait for creator deletion'
            removing.result()
            denied = uploading.result()
            assert denied.returncode != 0 and 'admin_forbidden' in denied.stderr
        assert value(f"select count(*) from storage.objects where starts_with(name,'{target}/');") == '0'
        print('PASS creator deletion commits first and the waiting service upload is denied', flush=True)

        operation = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=2) as pool:
            reserving = pool.submit(sql, "begin; set local application_name='paul-reservation-race';" + f"select public.admin_prepare_create('{actors[2]}','{operation}'); select pg_sleep(1); commit;")
            wait_barrier()
            removing = pool.submit(sql, remove(2))
            time.sleep(.1)
            assert not removing.done()
            reserved_result = reserving.result()
            removing.result()
        target = next(line for line in reserved_result.stdout.splitlines() if re.fullmatch(r'[a-f0-9-]{36}', line))
        profiles.append(target)
        assert value(f"select abandoned_profile_ids=array['{target}']::uuid[] from private.account_deletions where operation_id='{deletions[2]}';") == 't'
        assert 'profile_unavailable' in sql(upload(target), False).stderr
        print('PASS reservation creation serializes before deletion, its prefix persists, and late upload cannot restore it', flush=True)

        target, operation = prepare(3)
        sql(upload(target))
        draft = json.dumps({'name': 'Preserved completed managed QA', 'occupation': '', 'summary': 'Independent profile', 'skills': ['Design'], 'searching_skills': [], 'avatar_path': target + '/' + 'a' * 64 + '.png'})
        with ThreadPoolExecutor(max_workers=2) as pool:
            creating = pool.submit(sql, "begin; set local application_name='paul-reservation-race';" + f"select public.admin_save_profile('{actors[3]}','{target}',true,'{operation}','{draft}'::jsonb); select pg_sleep(1); commit;")
            wait_barrier()
            removing = pool.submit(sql, remove(3))
            time.sleep(.1)
            assert not removing.done()
            creating.result()
            removing.result()
        assert cleanup_objects(3) == []
        assert value(f"select cardinality(abandoned_profile_ids) from private.account_deletions where operation_id='{deletions[3]}';") == '0'
        assert value(f"select deleted_at is null from public.profiles where id='{target}';") == 't'
        assert value(f"select count(*) from storage.objects where starts_with(name,'{target}/');") == '1'
        print('PASS completed managed creation serializes before creator deletion and preserves its independent photo', flush=True)

        target, operation = prepare(4)
        sql(upload(target))
        draft = json.dumps({'name': 'Concurrent completed managed QA', 'occupation': '', 'summary': 'Preserved after creator deletion', 'skills': ['Design'], 'searching_skills': [], 'avatar_path': target + '/' + 'a' * 64 + '.png'})
        with ThreadPoolExecutor(max_workers=2) as pool:
            # The row barrier pauses the upload after its initial absent-profile
            # probe. Normal save and delete RPCs then publish the final state.
            completing = pool.submit(sql, "begin; set local application_name='paul-reservation-race';" + f"select 1 from public.profiles where id='{actors[4]}' for update; select pg_sleep(1); select public.admin_save_profile('{actors[4]}','{target}',true,'{operation}','{draft}'::jsonb);" + remove(4) + 'commit;')
            wait_barrier()
            late_upload = pool.submit(sql, upload(target).replace("repeat('a',64)", "repeat('b',64)"))
            time.sleep(.1)
            assert not late_upload.done()
            completing.result()
            late_upload.result()
        assert cleanup_objects(4) == []
        assert value(f"select count(*) from private.managed_profile_reservations where profile_id='{target}';") == '0'
        assert value(f"select count(*) from storage.objects where starts_with(name,'{target}/');") == '2'
        assert value(f"select deleted_at is null from public.profiles where id='{target}';") == 't'
        print('PASS an initially absent managed profile may finish during upload, lose its reservation, and keep both independent versions', flush=True)
    finally:
        all_ids = ','.join("'" + actor + "'" for actor in actors + profiles)
        sql(f"""delete from private.admin_audit where actor_user_id in({ids});
            delete from private.account_deletions where target_profile_id in({ids});
            delete from private.managed_profile_grants where user_id in({ids}) or profile_id in({all_ids});
            delete from private.managed_profile_reservations where actor_user_id in({ids});
            delete from private.admin_roles where user_id in({ids});
            delete from storage.objects where bucket_id='avatars' and lower(split_part(name,'/',1)) in({all_ids});
            delete from auth.sessions where user_id in({ids});
            delete from private.memberships where user_id in({ids});
            delete from public.profiles where id in({all_ids});
            delete from auth.users where id in({ids});
            delete from realtime.messages where topic in({','.join("'admin:user:"+actor+"'" for actor in actors)});""")


if __name__ == '__main__':
    main()
