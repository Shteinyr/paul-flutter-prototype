"""Concurrent profile writes against this task's isolated PostgreSQL only."""
import concurrent.futures
import json
import subprocess
import sys

if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-profile133-') or not sys.argv[2].startswith('paul_profile133'):
    raise SystemExit('Use a dedicated paul-profile133-* container and paul_profile133* database.')
container, database = sys.argv[1:]
actor = '13320000-0000-4000-8000-000000000001'

def sql(statement):
    return subprocess.run(['docker','exec','-i',container,'psql','-U','postgres','-d',database,'-X','-qAt','-v','ON_ERROR_STOP=1'],
                          input=statement,text=True,capture_output=True)

def literal(value):
    return "'" + str(value).replace("'", "''") + "'"

base = dict(name='Original', occupation='Designer', summary='Original summary', skills=['Design'], searching_skills=[], avatar_path=None)
def merge(index, changes, slow=False):
    operation=f'13320000-0000-4000-8000-{index:012d}'
    return sql('begin;set local role service_role;' +
               f'select public.merge_member_profile({literal(actor)},{literal(operation)},' +
               f'{literal(json.dumps(base))}::jsonb,{literal(json.dumps(changes))}::jsonb);' +
               ('select pg_sleep(0.2);' if slow else '') + 'commit;')

setup=sql(f'insert into auth.users(id) values({literal(actor)});' +
          f'select private.save_profile({literal(actor)},{literal(json.dumps(base))}::jsonb);' +
          f'insert into private.memberships(user_id) values({literal(actor)});')
if setup.returncode: raise SystemExit(setup.stderr)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    a=pool.submit(merge,10,dict(name='Device A'),True)
    b=pool.submit(merge,11,dict(summary='Device B'),True)
    results=[a.result(),b.result()]
if any(r.returncode for r in results):raise SystemExit('Disjoint concurrent writes failed')
proof=sql(f'select name,summary from public.profiles where id={literal(actor)};')
assert proof.stdout.strip()=='Device A|Device B',proof.stdout
# Both clients now try the same field from the same new snapshot.
base['name']='Device A';base['summary']='Device B'
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(lambda args:merge(*args),[(12,dict(name='Winner one'),True),(13,dict(name='Winner two'),True)]))
assert sum(r.returncode==0 for r in results)==1
assert all(r.returncode==0 or 'profile_conflict' in r.stderr for r in results)
# Eight retries must reuse one receipt instead of re-applying the mutation.
winner=12 if results[0].returncode==0 else 13
changes=dict(name='Winner one' if winner==12 else 'Winner two')
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    retries=list(pool.map(lambda _:merge(winner,changes),range(8)))
assert all(r.returncode==0 for r in retries)
proof=sql(f'select count(*) from private.profile_write_receipts where actor_id={literal(actor)};')
assert proof.stdout.strip()=='3',proof.stdout
print('PASS: two disjoint writers merge; same-field race has one conflict; eight retries reuse one receipt')
