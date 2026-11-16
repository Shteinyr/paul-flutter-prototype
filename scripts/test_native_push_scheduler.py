"""Exercise scheduler/Vault behavior in disposable Postgres, never hosted data."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import subprocess
import time


def main():
    root = Path(__file__).resolve().parents[1]
    container = f'paul-native-scheduler-{os.getpid()}'
    image = 'postgres:17-alpine3.23'
    subprocess.run(['docker', 'image', 'inspect', image], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['docker', 'run', '-d', '--rm', '--name', container,
                    '--network', 'none', '--memory', '256m',
                    '-e', 'POSTGRES_HOST_AUTH_METHOD=trust', image],
                   check=True, stdout=subprocess.DEVNULL)

    def sql(text, check=True):
        result = subprocess.run(['docker', 'exec', '-i', container, 'psql', '-U', 'postgres',
                                 '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'],
                                input=text, text=True, capture_output=True)
        if check and result.returncode:
            raise RuntimeError(result.stderr)
        return result

    def value(text):
        return sql(text).stdout.strip().splitlines()[-1]

    def extension(name, body):
        # pg_cron/pg_net are external services; emulate their public contracts.
        for suffix, data in [('control', "default_version = '1.0'\nrelocatable = false\n"),
                             ('--1.0.sql', body)]:
            filename = f'{name}.control' if suffix == 'control' else f'{name}{suffix}'
            subprocess.run(['docker', 'exec', '-i', container, 'sh', '-c',
                            f'cat > /usr/local/share/postgresql/extension/{filename}'],
                           input=data, text=True, check=True)
        sql(f'create extension {name};')

    try:
        for _ in range(60):
            if subprocess.run(['docker', 'exec', container, 'pg_isready', '-U', 'postgres'],
                              capture_output=True).returncode == 0:
                break
            time.sleep(.2)
        else:
            raise RuntimeError('Isolated PostgreSQL did not become ready.')
        sql((root / 'supabase/tests/bootstrap.sql').read_text())
        extension('pg_cron', '''
          create schema cron;
          create table cron.job(jobid bigserial primary key,jobname text unique,schedule text,command text,active boolean default true);
          create function cron.schedule(job_name text,schedule text,command text) returns bigint language sql as $$
            insert into cron.job(jobname,schedule,command) values($1,$2,$3) returning jobid;
          $$;
          create function cron.unschedule(job_id bigint) returns boolean language sql as $$
            with removed as (delete from cron.job where jobid=$1 returning 1) select exists(select from removed);
          $$;
          create function cron.alter_job(job_id bigint,active boolean) returns void language sql as $$
            update cron.job set active=$2 where jobid=$1;
          $$;
        ''')
        extension('pg_net', '''
          create schema net;
          create table net.requests(id bigserial primary key,url text,body jsonb,headers jsonb,timeout integer);
          create function net.http_post(url text,body jsonb,headers jsonb,timeout_milliseconds integer) returns bigint language sql as $$
            insert into net.requests(url,body,headers,timeout) values($1,$2,$3,$4) returning id;
          $$;
        ''')
        sql("select cron.schedule('paul-web-push-worker','* * * * *','web-existing');"
            "select cron.schedule('paul-maintenance-worker','* * * * *','maintenance-existing');"
            "select vault.create_secret('old-web-secret','paul_web_push_runtime');")
        sql((root / 'supabase/migrations/20261116040916_native_push_worker_scheduler.sql').read_text())
        signature = 'public.native_push_configure_scheduler(text,boolean)'
        for role in ['anon', 'authenticated']:
            assert value(f"select has_function_privilege('{role}','{signature}','execute');") == 'f'
            rejected = sql(f"set role {role}; select public.native_push_configure_scheduler('{'a' * 43}',false);", False)
            assert rejected.returncode and 'permission denied' in rejected.stderr
        assert value(f"select has_function_privilege('service_role','{signature}','execute');") == 't'
        assert value("select count(*) from cron.job where jobname='paul-native-push-worker';") == '0'
        print('PASS migration creates no job; ordinary callers cannot configure scheduling', flush=True)
        for secret in ['short', 'x' * 44, '!' * 43]:
            rejected = sql(f"select public.native_push_configure_scheduler('{secret}',false);", False)
            assert rejected.returncode and 'invalid_request' in rejected.stderr
        assert sql(f"select public.native_push_configure_scheduler('{'a' * 43}',null);", False).returncode
        assert value("select count(*) from vault.secrets where name='paul_native_push_runtime';") == '0'
        print('PASS invalid credentials/flags leave Vault and schedules unchanged', flush=True)

        def configure(enabled, secret='a' * 43):
            return sql(f"set role service_role; select public.native_push_configure_scheduler('{secret}',{str(enabled).lower()});")

        configure(False)
        assert value("select active from cron.job where jobname='paul-native-push-worker';") == 'f'
        command = value("select replace(command,E'\\n',' ') from cron.job where jobname='paul-native-push-worker';")
        assert 'a' * 43 not in command
        sql(command)
        assert value('select count(*) from net.requests;') == '0'
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda _: configure(False), range(6)))
        assert value("select count(*) from cron.job where jobname='paul-native-push-worker';") == '1'
        assert value("select count(*) from vault.secrets where name='paul_native_push_runtime';") == '1'
        print('PASS disabled runtime makes no request; concurrent retries keep one job and one Vault record', flush=True)
        configure(True, 'b' * 43)
        assert value("select active from cron.job where jobname='paul-native-push-worker';") == 't'
        sql(command)
        assert value('select count(*) from net.requests;') == '1'
        assert value("select headers->>'Authorization'='Bearer '||repeat('b',43) and body='{}'::jsonb and timeout=50000 and url='https://ejopxxhgozsxygvkwrfr.supabase.co/functions/v1/native-push-worker' from net.requests;") == 't'
        configure(False, 'b' * 43)
        sql(command)
        assert value('select count(*) from net.requests;') == '1'
        assert value("select count(*) from cron.job where (jobname,command,active) in (('paul-web-push-worker','web-existing',true),('paul-maintenance-worker','maintenance-existing',true));") == '2'
        assert value("select secret from vault.secrets where name='paul_web_push_runtime';") == 'old-web-secret'
        print('PASS explicit enable/rotation/disable; bearer is read at execution; existing workers preserved', flush=True)
        sql('drop extension pg_net cascade;')
        rejected = sql(f"select public.native_push_configure_scheduler('{'a' * 43}',true);", False)
        assert rejected.returncode and 'server_unavailable' in rejected.stderr
        assert value("select active from cron.job where jobname='paul-native-push-worker';") == 'f'
        print('PASS missing dependency fails without reactivating the worker', flush=True)
    finally:
        subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
        if subprocess.run(['docker', 'inspect', container], capture_output=True).returncode == 0:
            raise RuntimeError('Own scheduler test container was not removed.')
        print('PASS own container removed; no ports or volumes created', flush=True)


if __name__ == '__main__':
    main()
