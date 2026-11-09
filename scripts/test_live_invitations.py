"""Exercise the live invitation API with explicitly prepared disposable QA users.

The private fixture holds accounts and sessions. Never print its contents or use
real customer accounts. Seed/limit/expiry changes are performed separately by the
project owner so this runner cannot mutate arbitrary server configuration.
"""

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import ssl
import urllib.error
import urllib.request


def request(path, data=None, account=None, method='POST', raw=False):
    headers = {'apikey': args.publishable_key, 'Content-Type': 'image/png' if raw else 'application/json'}
    if account is not None:
        headers['Authorization'] = 'Bearer ' + account['session']['access_token']
    body = data if raw else None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(args.url.rstrip('/') + path, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=45, context=tls) as response:
            content = response.read()
            if raw:
                return response.status, content
            return response.status, json.loads(content) if content else {}
    except urllib.error.HTTPError as error:
        try:
            content = json.loads(error.read())
        except (ValueError, UnicodeError):
            content = {}
        # Errors deliberately exclude token-bearing response content.
        return error.code, {'code': content.get('code') or content.get('error_code')}


def api(action, fields=None, account=None):
    return request('/functions/v1/invitations', {'action': action, **(fields or {})}, account)


def expect(response, status, description, code=None):
    actual, body = response
    if actual != status or (code is not None and body.get('code') != code):
        raise AssertionError(f'{description}: expected HTTP {status}, received {actual}, code={body.get("code")}')
    print('PASS ' + description)
    return body


def save_fixture():
    args.fixture.write_text(json.dumps(fixture))
    os.chmod(args.fixture, 0o600)


def upload(account):
    path = account['id'] + '/' + hashlib.sha256(png).hexdigest() + '.png'
    status, _ = request('/storage/v1/object/avatars/' + path, png, account, raw=True)
    if status not in (200, 201, 400, 409):
        raise AssertionError(f'Own avatar upload failed HTTP {status}')
    # Confirm storage actually holds the private image, including upload retries.
    status, _ = request('/storage/v1/object/authenticated/avatars/' + path, account=account, method='GET', raw=True)
    if status != 200:
        raise AssertionError(f'Own avatar was not readable HTTP {status}')
    account['avatar_path'] = path
    return path


def profile(account, name):
    return {'name': name, 'occupation': '', 'summary': 'Disposable Paul integration test profile',
            'skills': ['Flutter'], 'searching_skills': ['Flutter'], 'avatar_path': account['avatar_path']}


def issue(account):
    token = secrets.token_hex(32)
    data = expect(api('issue', {'token': token}, account), 200, 'real server issuance')
    expires = datetime.fromisoformat(data['expires_at'])
    server_now = datetime.fromisoformat(data['server_now'])
    assert 0 < (expires - server_now).total_seconds() <= 900
    return {**data, 'token': token}


def login_all():
    for account in accounts:
        response = request('/auth/v1/token?grant_type=password', {'email': account['email'], 'password': account['password']})
        account['session'] = expect(response, 200, 'GoTrue sign-in for disposable ' + account['label'])
    save_fixture()


def basic():
    login_all()
    inviter, invitee, outsider, _ = accounts
    expect(api('issue', {'token': secrets.token_hex(32)}), 401, 'anonymous issuance denied', 'sign_in_required')
    expect(api('network'), 401, 'anonymous network denied', 'sign_in_required')
    upload(inviter)
    network = expect(api('network', account=inviter), 200, 'initial membership lookup')
    if network['profile'] is None:
        expect(api('redeem', {'credential': fixture['root_invitation'], 'profile': profile(inviter, 'QA Inviter')}, inviter), 200,
               'one-use owner bootstrap through authenticated private upload')
    invitation = issue(inviter)
    fixture['issued'] = invitation
    save_fixture()
    expect(api('check', {'credential': invitation['code']}), 200, 'manual code resolves the same live invitation')
    upload(invitee)
    draft = profile(invitee, 'QA Invitee')
    expect(api('redeem', {'credential': invitation['token'], 'profile': {**draft, 'avatar_path': None}}, invitee), 400,
           'activation without mandatory photo denied', 'invalid_profile')
    expect(api('redeem', {'credential': invitation['token'], 'profile': {**draft, 'avatar_path': invitee['id'] + '/' + '0' * 64 + '.png'}}, invitee), 400,
           'activation with nonexistent photo denied', 'invalid_profile')
    expect(api('redeem', {'credential': invitation['token'], 'profile': {**draft, 'avatar_path': inviter['avatar_path']}}, invitee), 400,
           'activation with another user photo denied', 'invalid_profile')
    expect(api('redeem', {'credential': invitation['token'], 'profile': {**draft, 'skills': ['Flutter', ' flutter ']}}, invitee), 400,
           'case and whitespace duplicates denied within offered list', 'invalid_profile')
    expect(api('redeem', {'credential': invitation['token'], 'profile': {**draft, 'searching_skills': ['Flutter', ' flutter ']}}, invitee), 400,
           'case and whitespace duplicates denied within seeking list', 'invalid_profile')
    draft['skills'].append('e\u0301' * 64)
    expect(api('redeem', {'credential': invitation['token'], 'profile': draft}, invitee), 200,
           'registration accepts optional occupation, overlap and 64 graphemes')
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: api('redeem', {'credential': invitation['token']}, invitee), range(2)))
    for result in results:
        expect(result, 200, 'duplicate authenticated callback is idempotent')
    network = expect(api('network', account=invitee), 200, 'registered network reload')
    assert network['profile']['contact_count'] == 1
    assert len(network['contacts']) == 1 and network['contacts'][0]['id'] == inviter['id']
    assert network['contacts'][0]['contact_count'] == 1
    expect(api('save_profile', {'profile': {**draft, 'skills': ['e\u0301' * 65]}}, invitee), 400,
           '65 graphemes rejected at HTTP boundary', 'invalid_profile')
    data = expect(api('network', account=outsider), 200, 'nonmember session stays inactive')
    assert data == {'profile': None, 'contacts': []}
    data = expect(request('/rest/v1/profiles?select=id', account=outsider, method='GET'), 200, 'RLS blocks nonmember profile reads')
    assert data == []
    status, _ = request('/storage/v1/object/authenticated/avatars/' + inviter['avatar_path'], account=outsider, method='GET', raw=True)
    assert status >= 400
    print('PASS RLS blocks unrelated private avatar reads')
    status, _ = request('/storage/v1/object/authenticated/avatars/' + inviter['avatar_path'], account=invitee, method='GET', raw=True)
    assert status == 200
    print('PASS connected member can read the inviter private avatar')
    status, _ = request('/rest/v1/rpc/redeem_invitation', {'p_user': outsider['id'], 'p_hash': '0'*64, 'p_manual': False, 'p_profile': {}}, invitee)
    assert status >= 400
    print('PASS direct service RPC cannot spoof another user')
    expect(api('revoke', {'id': invitation['id']}, invitee), 200, 'nonowner revoke is harmless')
    expect(api('check', {'credential': invitation['token']}), 200, 'nonowner cannot revoke another invitation')
    expect(api('revoke', {'id': invitation['id']}, inviter), 200, 'owner revokes invitation')
    expect(api('check', {'credential': invitation['token']}), 400, 'revoked invitation rejected', 'invalid_invitation')
    fixture['rotation_invitation'] = issue(inviter)
    fixture['last_use_invitation'] = issue(inviter)
    save_fixture()
    print('Saved private fixtures for actual 15-minute expiry and concurrent last-use checks')


def last_use():
    invitation = fixture['last_use_invitation']
    contenders = accounts[2:]
    for account in contenders:
        upload(account)
    def redeem(account):
        return api('redeem', {'credential': invitation['token'], 'profile': profile(account, 'QA concurrent member')}, account)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(redeem, contenders))
    assert sorted(status for status, _ in results) == [200, 400]
    assert any(body.get('code') == 'invalid_invitation' for status, body in results if status == 400)
    print('PASS two simultaneous final-use redemptions yield exactly one member')
    network_results = [api('network', account=account)[1] for account in contenders]
    assert sum(data.get('profile') is not None for data in network_results) == 1
    print('PASS failed contender retains no active profile or connection')
    save_fixture()


def rate():
    for _ in range(23):
        status, body = api('check', {'credential': '00000000'})
        if status == 429 and body.get('code') == 'rate_limited':
            print('PASS brute-force budget rejects excess lookups')
            return
    raise AssertionError('Expected lookup rate limit')


def expiry():
    invitation = fixture['rotation_invitation']
    expires = datetime.fromisoformat(invitation['expires_at'])
    if datetime.now(timezone.utc) <= expires:
        raise SystemExit('Actual 15-minute deadline has not passed yet')
    expect(api('check', {'credential': invitation['token']}), 400, 'actual expired token rejected', 'invalid_invitation')
    expect(api('check', {'credential': invitation['code']}), 400, 'actual expired numeric code rejected', 'invalid_invitation')
    expect(api('issue', {'token': invitation['token']}, accounts[0]), 400, 'retry cannot revive or extend expired token', 'invalid_invitation')



if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture', required=True, type=Path)
    parser.add_argument('--url', required=True)
    parser.add_argument('--publishable-key', required=True)
    parser.add_argument('--phase', choices=['basic', 'last-use', 'rate', 'expiry'], default='basic')
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    accounts = fixture['accounts']
    certificate_bundle = '/etc/ssl/cert.pem'
    tls = ssl.create_default_context(cafile=certificate_bundle if Path(certificate_bundle).exists() else None)
    png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=')
    
    
    try:
        {'basic': basic, 'last-use': last_use, 'rate': rate, 'expiry': expiry}[args.phase]()
    except (urllib.error.URLError, TimeoutError):
        raise SystemExit('Network verification failed. Credentials and request bodies were not printed.') from None
