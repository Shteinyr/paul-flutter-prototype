"""Real PostgreSQL races + filesystem/HTTP Storage stand-in, NEVER hosted Storage.

Run after the application migrations in an owned empty paul_photo73* database.
The production SDK and cleanupAvatars run unchanged against this local fixture.
"""
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-') or not sys.argv[2].startswith('paul_photo73'):
        raise SystemExit('Only an isolated Paul container / paul_photo73* database is allowed.')
    container, database = sys.argv[1:]
    actor = '73600000-0000-4000-8000-000000000001'
    names = {key: actor + '/' + key * 64 + '.png' for key in 'abcdef0123'}
    files = {}
    deletes = []
    fail_once = {names['d']}

    def literal(value):
        return "'" + str(value).replace("'", "''") + "'"

    def sql(statement, check=True):
        return subprocess.run(['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database,
                               '-X', '-qAt', '-v', 'ON_ERROR_STOP=1'], input=statement, text=True,
                              capture_output=True, check=check)

    def result(statement):
        output = sql(statement).stdout.strip().splitlines()
        if not output or not output[-1]:
            return None
        if output[-1] in ('t', 'f'):
            return output[-1] == 't'
        return json.loads(output[-1])

    def claim():
        return result('set role service_role;select public.avatar_cleanup_claim();')

    def age(name):
        sql('update private.avatar_uploads set protected_until=clock_timestamp()-interval \'1 second\', '
            'next_attempt_at=clock_timestamp()-interval \'1 second\' where path=' + literal(name))

    def upload(key, root):
        name = names[key]
        path = root / (key + '.png')
        path.write_bytes(b'local-photo-' + key.encode())
        files[name] = path
        sql("insert into storage.objects(id,bucket_id,name,owner_id) values(" + literal(uuid.uuid4()) +
            ",'avatars'," + literal(name) + ',' + literal(actor) + ');')

    def wait_sleep(app):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if result("select exists(select 1 from pg_stat_activity where application_name=" + literal(app) +
                      " and wait_event='PgSleep');"):
                return
            time.sleep(.03)
        raise AssertionError('Concurrent transaction did not reach its lock-holding barrier')

    class Storage(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                action = self.path.rsplit('/', 1)[-1]
                if action == 'avatar_cleanup_claim':
                    statement = 'public.avatar_cleanup_claim(5)'
                elif action == 'avatar_cleanup_prepare':
                    statement = 'public.avatar_cleanup_prepare(' + literal(body['p_path']) + ',' + literal(body['p_lease']) + ')'
                elif action == 'avatar_cleanup_finish':
                    statement = 'public.avatar_cleanup_finish(' + literal(body['p_path']) + ',' + literal(body['p_lease']) + ',' + ('true' if body['p_success'] else 'false') + ')'
                else:
                    raise AssertionError('Unexpected RPC')
                self.reply(200, result('set role service_role;select ' + statement))
            except Exception:
                self.reply(500, {'message': 'local_fixture_error'})

        def do_DELETE(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            assert self.path == '/storage/v1/object/avatars'
            paths = body['prefixes']
            assert all(path in files for path in paths)
            if any(path in fail_once for path in paths):
                fail_once.difference_update(paths)
                self.reply(503, {'message': 'storage_unavailable', 'statusCode': '503'})
                return
            for name in paths:
                # Only this local stand-in mutates its own metadata/files. The
                # production worker uses storage.remove, never SQL DELETE.
                files[name].unlink(missing_ok=True)
                sql("delete from storage.objects where bucket_id='avatars' and name=" + literal(name))
                deletes.append(name)
            self.reply(200, [{'name': path} for path in paths])

        def reply(self, status, body):
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    def run_worker(port):
        run = subprocess.run([shutil.which('deno'), 'run', '--allow-env', '--allow-net=127.0.0.1:' + str(port),
                              'scripts/avatar_cleanup_probe.ts', f'http://127.0.0.1:{port}'],
                             capture_output=True, text=True, check=True)
        return json.loads(run.stdout.strip().splitlines()[-1])

    server = None
    try:
        sql('update private.avatar_cleanup_settings set enabled=false;')
        sql("insert into auth.users(id) values(" + literal(actor) + ');' +
            "insert into public.profiles(id,name,occupation,summary,skills) values(" + literal(actor) +
            ",'Local photo lifecycle','','Test',array['Design']);")
        with tempfile.TemporaryDirectory(prefix='paul-photo73-') as temporary:
            root = Path(temporary)
            for key in 'abcd':
                upload(key, root)
            sql('update public.profiles set avatar_path=' + literal(names['a']) + ' where id=' + literal(actor))
            sql('update public.profiles set avatar_path=' + literal(names['b']) + ' where id=' + literal(actor))
            age(names['a'])
            age(names['d'])
            assert claim() == []  # disabled by default
            sql('set role service_role;select public.avatar_cleanup_set_enabled(true)')
            server = ThreadingHTTPServer(('127.0.0.1', 0), Storage)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            first = run_worker(server.server_port)
            assert first['complete'] == 1 and first['retry'] == 1, first
            assert not files[names['a']].exists()
            assert files[names['b']].exists() and files[names['c']].exists() and files[names['d']].exists()
            age(names['d'])
            second = run_worker(server.server_port)
            assert second['complete'] == 1 and not files[names['d']].exists(), second

            # Finalization wins: holding a path lock must make cleanup skip it.
            upload('e', root)
            age(names['e'])
            with ThreadPoolExecutor(max_workers=2) as pool:
                finalizing = pool.submit(sql, "set application_name='photo73-finalize';begin;update public.profiles set avatar_path=" +
                                         literal(names['e']) + ' where id=' + literal(actor) + ';select pg_sleep(1);commit;')
                wait_sleep('photo73-finalize')
                assert not any(j['path'] == names['e'] for j in claim())
                finalizing.result()
            assert not any(j['path'] == names['e'] for j in claim())

            # An upload holds the existing profile guard before its path lock.
            # Concurrent profile save follows profile -> path too, without deadlock.
            upload('f', root)
            age(names['f'])
            with ThreadPoolExecutor(max_workers=2) as pool:
                renewing = pool.submit(sql, "set application_name='photo73-upload';begin;update storage.objects set owner_id=owner_id where name=" +
                                       literal(names['f']) + ';select pg_sleep(1);commit;')
                wait_sleep('photo73-upload')
                assert not any(j['path'] == names['f'] for j in claim())
                saving = pool.submit(sql, 'update public.profiles set avatar_path=' + literal(names['f']) + ' where id=' + literal(actor))
                renewing.result()
                saving.result()
            assert result('select protected_until>clock_timestamp() from private.avatar_uploads where path=' + literal(names['f']))

            # Cleanup wins. Expired/stale leases never allow this path to be reused.
            upload('0', root)
            age(names['0'])
            old = next(j for j in claim() if j['path'] == names['0'])
            args = literal(old['path']) + ',' + literal(old['lease_token'])
            assert result('set role service_role;select public.avatar_cleanup_prepare(' + args + ')')['exists']
            rejected = sql('update public.profiles set avatar_path=' + literal(names['0']) + ' where id=' + literal(actor), False)
            assert rejected.returncode and 'avatar_retired' in rejected.stderr
            sql('update private.avatar_uploads set lease_until=clock_timestamp()-interval \'1 second\' where path=' + literal(names['0']))
            new = next(j for j in claim() if j['path'] == names['0'])
            assert new['lease_token'] != old['lease_token']
            assert result('set role service_role;select public.avatar_cleanup_finish(' + args + ',true)') is None
            reupload = sql('update storage.objects set owner_id=owner_id where name=' + literal(names['0']), False)
            assert reupload.returncode and 'avatar_retired' in reupload.stderr
            upload('1', root)
            sql('update public.profiles set avatar_path=' + literal(names['1']) + ' where id=' + literal(actor))
            # Simulate the old, delayed HTTP DELETE after the new lease and upload.
            import urllib.request
            req = urllib.request.Request(f'http://127.0.0.1:{server.server_port}/storage/v1/object/avatars',
                                         data=json.dumps({'prefixes': [names['0']]}).encode(), method='DELETE',
                                         headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req) as response:
                assert response.status == 200
            assert files[names['1']].exists() and files[names['f']].exists()
            print(json.dumps({'storage_sdk_http': 'PASS', 'replacement': 'PASS', 'abandoned': 'PASS',
                              'active_upload': 'PASS', 'finalize_wins': 'PASS', 'cleanup_wins': 'PASS',
                              'lock_order': 'PASS', 'expired_lease_late_delete': 'PASS', 'partial_failure_retry': 'PASS',
                              'first': first, 'second': second, 'external_deletes': len(deletes)}))
    finally:
        if server:
            server.shutdown()
            server.server_close()
        sql('update private.avatar_cleanup_settings set enabled=false;')
        # Only this script's disposable fixture; unrelated databases are untouched.
        sql("delete from storage.objects where bucket_id='avatars' and starts_with(name," + literal(actor + '/') + ');' +
            'delete from private.avatar_uploads where owner_profile_id=' + literal(actor) + ';' +
            'delete from public.profiles where id=' + literal(actor) + ';delete from auth.users where id=' + literal(actor) + ';')


if __name__ == '__main__':
    main()
