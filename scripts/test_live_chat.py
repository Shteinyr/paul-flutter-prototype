"""Live gate restricted to the explicitly assigned disposable Paul QA pair.

Pass public config and the private QA fixture paths. Fresh sessions remain in
memory. This runner never rewrites shared fixture sessions or profile fields.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import secrets
from pathlib import Path
import ssl
import urllib.error
import urllib.request
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--fixture', type=Path, required=True)
    parser.add_argument('--connections', action='store_true')
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    fixture = json.loads(args.fixture.read_text())
    base = config['SUPABASE_URL']
    assert base == 'https://ejopxxhgozsxygvkwrfr.supabase.co'
    tls = ssl.create_default_context(cafile='/etc/ssl/cert.pem')

    def request(path, body=None, session=None, method='POST'):
        headers = {'apikey': config['SUPABASE_PUBLISHABLE_KEY'], 'Content-Type': 'application/json'}
        if session:
            headers['Authorization'] = 'Bearer ' + session['access_token']
        req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, context=tls, timeout=45) as response:
                return response.status, json.load(response)
        except urllib.error.HTTPError as error:
            try:
                data = json.load(error)
            except ValueError:
                data = {}
            return error.code, {'code': data.get('code')}

    def check(result, status, description, code=None):
        actual, data = result
        assert actual == status, f'{description}: HTTP {actual}'
        assert code is None or data.get('code') == code, description
        print('PASS ' + description, flush=True)
        return data

    def login(account):
        return check(request('/auth/v1/token?grant_type=password', {
            'email': account['email'], 'password': account['password'],
        }), 200, 'fresh GoTrue session for assigned disposable identity')

    accounts = fixture['accounts']
    a = accounts[fixture['review_roles']['implementation']]
    b = accounts[fixture['review_roles']['coordinator']]
    outsider = next(account for account in accounts if account['id'] not in (a['id'], b['id']))
    sa, sb, sc = login(a), login(b), login(outsider)

    def api(action, session=None, **fields):
        return request('/functions/v1/chat', {'action': action, **fields}, session)

    check(api('list'), 401, 'anonymous chat denied', 'sign_in_required')
    check(api('open', sa, peer_id=a['id']), 400, 'self-conversation rejected', 'self_conversation')
    conversation = check(api('open', sa, peer_id=b['id']), 200, 'assigned QA contacts open a persisted conversation')['id']
    other_open = check(api('open', sb, peer_id=a['id']), 200, 'reversed pair reopens the same conversation')
    assert other_open['id'] == conversation
    check(api('history', sc, conversation_id=conversation), 403, 'third account cannot read history', 'conversation_forbidden')
    check(api('send', sc, conversation_id=conversation, client_message_id=str(uuid.uuid4()), text='Disposable QA intrusion'),
          403, 'third account cannot send', 'conversation_forbidden')
    check(api('read', sc, conversation_id=conversation, through_seq=0), 403, 'third account cannot mark read', 'conversation_forbidden')
    check(request('/rest/v1/messages?conversation_id=eq.' + conversation, session=sc, method='GET'),
          200, 'Data API applies participant RLS')
    assert request('/rest/v1/messages?conversation_id=eq.' + conversation, session=sc, method='GET')[1] == []
    check(api('send', sa, conversation_id=conversation, client_message_id=str(uuid.uuid4()),
              text='Disposable QA', sender_profile_id=b['id']), 400, 'spoofed sender field rejected', 'invalid_request')

    original = check(api('history', sb, conversation_id=conversation), 200, 'initial persisted sequence loaded')
    baseline = original['last_message_seq']
    check(api('read', sb, conversation_id=conversation, through_seq=baseline), 200, 'bounded read cursor accepted')
    message_id = str(uuid.uuid4())
    payload = {'conversation_id': conversation, 'client_message_id': message_id, 'text': 'Disposable P10 QA A'}
    with ThreadPoolExecutor(max_workers=8) as pool:
        responses = list(pool.map(lambda _: api('send', sa, **payload), range(8)))
    acknowledged = [check(result, 200, 'concurrent retry acknowledged') for result in responses]
    assert len({item['message']['id'] for item in acknowledged}) == 1
    assert sum(not item['replayed'] for item in acknowledged) == 1
    check(api('send', sa, **{**payload, 'text': 'Changed payload'}), 409, 'same ID with changed text conflicts', 'message_id_conflict')
    reply = check(api('send', sb, conversation_id=conversation, client_message_id=str(uuid.uuid4()),
                      text='Disposable P10 QA B'), 200, 'second real Auth identity sends a persisted reply')
    history = check(api('history', sa, conversation_id=conversation, after_seq=baseline, limit=100), 200, 'forward catch-up after retries')
    assert len(history['messages']) == 2
    assert history['messages'][0]['seq'] == baseline + 1
    assert history['messages'][1]['id'] == reply['message']['id']
    roster = check(api('list', sb), 200, 'conversation list reads persisted unread')
    thread = next(item for item in roster['conversations'] if item['id'] == conversation)
    assert thread['unread_count'] == 1
    check(api('read', sb, conversation_id=conversation, through_seq=baseline + 2), 200, 'mark visible history read')
    check(api('read', sb, conversation_id=conversation, through_seq=baseline + 100), 400, 'future read cursor rejected', 'invalid_request')
    for text in [' \n\t', 'bad\0text', 'e\u0301' * 2001]:
        check(api('send', sa, conversation_id=conversation, client_message_id=str(uuid.uuid4()), text=text),
              400, 'invalid live Unicode text rejected', 'invalid_message')
    check(request('/functions/v1/chat', {'action': 'list', 'oversize': 'x' * 71000}, sa),
          413, 'oversized live request rejected before parsing', 'request_too_large')
    if args.connections:
        token = secrets.token_hex(32)
        invitation = check(request('/functions/v1/invitations', {'action': 'issue', 'token': token}, sa),
                           200, 'fresh QA invitation for explicit re-invite concurrency contract')
        check(request('/functions/v1/invitations', {'action': 'redeem', 'credential': token}, sb),
              200, 'current participant explicitly accepts invitation')
        operation = str(uuid.uuid4())
        try:
            check(api('disconnect', sa, peer_id=b['id'], client_operation_id=operation), 200, 'connection removed with operation ID')
            replay = check(request('/functions/v1/invitations', {'action': 'redeem', 'credential': token}, sb),
                           200, 'old invitation replay remains safe after removal')
            assert replay['replayed'] and not replay['connected']
            old = check(api('send', sa, **payload), 200, 'old message retry cannot reconnect')
            assert old['replayed'] and not old['connected']
            fresh_a = check(api('send', sa, conversation_id=conversation, client_message_id=str(uuid.uuid4()), text='Fresh disposable A'),
                            200, 'first fresh message after removal')
            assert not fresh_a['connected']
            fresh_b = check(api('send', sb, conversation_id=conversation, client_message_id=str(uuid.uuid4()), text='Fresh disposable B'),
                            200, 'second fresh sender reconnects atomically')
            assert fresh_b['connected']
            repeated = check(api('disconnect', sa, peer_id=b['id'], client_operation_id=operation), 200, 'old removal replay is idempotent')
            assert repeated['replayed']
            network = check(request('/functions/v1/invitations', {'action': 'network'}, sa), 200, 'original QA direct connection restored')
            assert any(peer['id'] == b['id'] for peer in network['contacts'])
        finally:
            # Restore the approved QA pair through its normal fresh-exchange rule.
            check(api('send', sa, conversation_id=conversation, client_message_id=str(uuid.uuid4()), text='QA restore A'), 200, 'QA pair restore message A')
            check(api('send', sb, conversation_id=conversation, client_message_id=str(uuid.uuid4()), text='QA restore B'), 200, 'QA pair restore message B')
            check(request('/functions/v1/invitations', {'action': 'revoke', 'id': invitation['id']}, sa), 200, 'own QA invitation revoked')
    print('PASS live chat gate complete without shared fixture or profile mutations', flush=True)


if __name__ == '__main__':
    main()
