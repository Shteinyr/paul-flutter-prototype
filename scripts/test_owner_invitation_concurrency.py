"""Run only against an explicitly named isolated SQL test container."""
import concurrent.futures
import subprocess
import sys


container = sys.argv[1]
if not container.startswith("paul-owner"):
    raise SystemExit("Use an isolated paul-owner* test container")
database = sys.argv[2] if len(sys.argv) > 2 else "postgres"
if database != "postgres" and not database.startswith("owner77_"):
    raise SystemExit("Use an isolated owner77_* database")


def sql(statement):
    return subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-U", "postgres", "-d", database, "-X", "-At", "-v", "ON_ERROR_STOP=1"],
        input=statement, text=True, capture_output=True,
    )


users = [f"77100000-0000-4000-8000-{index:012d}" for index in (1, 2)]
setup = "\n".join(
    f"insert into auth.users(id) values('{user}');"
    f"insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),"
    f"'avatars','{user}/'||repeat('f',64)||'.png','{user}');"
    for user in users
)
setup += "select public.issue_owner_registration_invitation(repeat('e',64),'verified@example.test');"
result = sql(setup)
if result.returncode:
    raise SystemExit(result.stderr)


def redeem(user):
    return sql(
        "set role service_role;"
        f"select public.redeem_registration_invitation('{user}',repeat('e',64),false,"
        f"jsonb_build_object('name','Concurrent owner QA','occupation','','summary','Test',"
        f"'skills',array['Flutter'],'searching_skills','[]'::jsonb,"
        f"'avatar_path','{user}/'||repeat('f',64)||'.png'),'verified@example.test');"
    )


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(redeem, users))
if sum(result.returncode == 0 for result in results) != 1:
    raise SystemExit("One private link must produce exactly one successful claimant")
if any(result.returncode and "invalid_invitation" not in result.stderr for result in results):
    raise SystemExit("Concurrent rejection must be an ordinary invalid invitation")
proof = sql(
    "select count(*) from private.admin_roles where user_id::text like '77100000-%';"
    "select count(*) from private.memberships where user_id::text like '77100000-%';"
    "select count(*) from private.admin_audit where actor_user_id::text like '77100000-%' "
    "and action='owner_invitation_accepted';"
)
if proof.returncode or proof.stdout.splitlines() != ["1", "1", "1"]:
    raise SystemExit("One role, membership and audit record must commit together")
winner = sql("select claimed_by from private.owner_registration_invitations where token_hash=repeat('e',64);").stdout.strip()
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
    replay = list(pool.map(redeem, [winner] * 8))
if any(result.returncode or '"replayed": true' not in result.stdout for result in replay):
    raise SystemExit("All same-account lost-response retries must succeed idempotently")
print("PASS: competing registrations create one owner; eight retries reuse the same claim")
