"""First-send quotas and completed registrations in an isolated Paul MVP database."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import subprocess
import sys
import uuid


def main():
    if len(sys.argv) != 3 or not sys.argv[1].startswith('paul-mvp') or not sys.argv[2].startswith('paul_mvp'):
        raise SystemExit('Pass the isolated paul-mvp container and paul_mvp database.')
    container, database = sys.argv[1:]
    people = [f'86300000-0000-4000-8000-{n:012d}' for n in range(1, 6)]
    actor, first, second, other, newcomer = people

    def sql(statement, check=True):
        return subprocess.run(['docker', 'exec', '-i', container, 'psql', '-U', 'postgres', '-d', database, '-X', '-At', '-v', 'ON_ERROR_STOP=1'], input=statement, text=True, capture_output=True, check=check)

    def value(statement):
        return sql(statement).stdout.strip().splitlines()[-1]

    ids = ','.join("'" + person + "'" for person in people)
    sql(f"""insert into auth.users(id) values {','.join("('"+person+"')" for person in people)};
        select private.save_profile(id,jsonb_build_object('name','MVP race QA','occupation','','summary','Test','skills',array['Design'],'searching_skills','[]'::jsonb)) from auth.users where id in({ids}) and id<>'{newcomer}';
        insert into private.memberships(user_id) select id from public.profiles where id in({ids});
        insert into storage.objects(id,bucket_id,name,owner_id) values(gen_random_uuid(),'avatars','{newcomer}/'||repeat('c',64)||'.png','{newcomer}');""")
    try:
        conversations = [value(f"select public.chat_open('{actor}','{peer}')->>'id';") for peer in (first, second)]
        operations = [str(uuid.uuid4()), str(uuid.uuid4())]

        def send(index):
            return sql(f"select public.chat_send('{actor}','{conversations[index]}','{operations[index]}','MVP quota race {index}');", False)

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(send, range(2)))
        assert sum(result.returncode == 0 for result in results) == 1
        assert all(result.returncode == 0 or 'new_contact_limit_reached' in result.stderr for result in results)
        winner = next(index for index, result in enumerate(results) if result.returncode == 0)
        loser = 1 - winner
        assert value(f"select last_message_seq from public.conversations where id='{conversations[loser]}';") == '0'
        assert value(f"select count(*) from public.messages where actor_user_id='{actor}';") == '1'
        assert value(f"select count(*) from private.notification_jobs where conversation_id in('{conversations[0]}','{conversations[1]}');") == '1'
        assert value(f"select count(*) from private.first_contact_days where actor_profile_id='{actor}';") == '1'
        assert send(loser).returncode != 0
        assert json.loads(send(winner).stdout.splitlines()[-1])['replayed'] is True
        assert value(f"select last_message_seq from public.conversations where id='{conversations[loser]}';") == '0'
        assert value(f"select count(*) from public.messages where actor_user_id='{actor}';") == '1'
        assert value(f"select count(*) from private.notification_jobs where conversation_id in('{conversations[0]}','{conversations[1]}');") == '1'
        print('PASS competing first sends admit one peer and losing retry leaves no sequence/message/outbox/quota residue', flush=True)

        sql(f"update private.first_contact_days set day_utc=(clock_timestamp() at time zone 'UTC')::date-1 where actor_profile_id='{actor}';")
        assert send(loser).returncode == 0
        assert value(f"select count(*) from private.first_contact_days where actor_profile_id='{actor}';") == '2'
        print('PASS the same previously rejected command can send in the next UTC window', flush=True)

        conversation = value(f"select public.chat_open('{other}','{first}')->>'id';")
        operation = str(uuid.uuid4())
        with ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: sql(f"select public.chat_send('{other}','{conversation}','{operation}','MVP same-id retry');"), range(8)))
        assert value(f"select count(*) from public.messages where actor_user_id='{other}';") == '1'
        assert value(f"select count(*) from private.first_contact_days where actor_profile_id='{other}';") == '1'
        print('PASS eight first-send retries commit one message and one quota receipt', flush=True)

        tokens = [hashlib.sha256(f'mvp-race-{n}'.encode()).hexdigest() for n in range(2)]
        for inviter, token in zip((actor, other), tokens):
            sql(f"select public.issue_invitation('{inviter}','{token}','{hashlib.sha256(token.encode()).hexdigest()}');")
        draft = json.dumps({'name': 'MVP invited QA', 'occupation': '', 'summary': 'Test', 'skills': ['Design'], 'searching_skills': [], 'avatar_path': newcomer + '/' + 'c' * 64 + '.png'})
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda token: sql(f"select public.redeem_invitation('{newcomer}','{token}',false,'{draft}'::jsonb);"), tokens))
        assert value(f"select count(*) from private.invited_registrations where invitee_profile_id='{newcomer}';") == '1'
        assert value(f"select private.invited_registration_count('{actor}')+private.invited_registration_count('{other}');") == '1'
        for token in tokens:
            sql(f"select public.redeem_invitation('{newcomer}','{token}',false,'{{}}'::jsonb);")
        sql(f"select public.redeem_invitation('{first}','{tokens[0]}',false,'{{}}'::jsonb);")
        assert value(f"select private.invited_registration_count('{actor}')+private.invited_registration_count('{other}');") == '1'
        print('PASS competing invitations credit one completed registration and existing-member redemptions never increase the level', flush=True)
    finally:
        sql(f"""delete from private.notification_jobs where conversation_id in(select id from public.conversations where user_low in({ids}) and user_high in({ids}));
            delete from public.messages where actor_user_id in({ids});
            delete from public.conversation_members where conversation_id in(select id from public.conversations where user_low in({ids}) and user_high in({ids}));
            delete from public.conversations where user_low in({ids}) and user_high in({ids});
            delete from public.connections where user_low in({ids}) and user_high in({ids});
            delete from private.first_contact_days where actor_profile_id in({ids});
            delete from private.invited_registrations where invitee_profile_id in({ids}) or inviter_profile_id in({ids});
            delete from private.invitations where issuer_id in({ids});
            delete from storage.objects where owner_id in({','.join("'"+p+"'" for p in people)});
            delete from private.memberships where user_id in({ids});
            delete from public.profiles where id in({ids});
            delete from auth.users where id in({ids});
            delete from realtime.messages where topic in({','.join("'chat:user:"+p+"'" for p in people)});""")


if __name__ == '__main__':
    main()
