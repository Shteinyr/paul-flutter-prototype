import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/auth_callback.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'live_chat_api_test.dart' show token;

const _user = '10000000-0000-4000-8000-000000000001';
const _other = '10000000-0000-4000-8000-000000000002';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

class _Storage extends GotrueAsyncStorage {
  final values = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => values[key];
  @override
  Future<void> setItem({required String key, required String value}) async =>
      values[key] = value;
  @override
  Future<void> removeItem({required String key}) async => values.remove(key);
}

Map<String, dynamic> _session(String id) => {
  'access_token': token(id),
  'refresh_token': 'local-refresh',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': id,
    'aud': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
  },
};

void main() {
  test(
    'ordinary invitation URLs are not exchanged or cleaned as auth',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://local.invalid',
        'local-key',
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 400);
        }),
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      try {
        final uri = Uri.parse(
          'https://app.invalid/?keep=1#invite=local-invite',
        );
        expect(
          await completeAuthCallback(client, uri),
          AuthCallbackResult.none,
        );
        expect(requests, 0);
        expect(withoutAuthCallbackParameters(uri), uri);
      } finally {
        await client.dispose();
      }
    },
  );

  for (final suffix in [
    '?auth=callback#error=access_denied&error_code=otp_expired&error_description=LOCAL_UNSAFE',
    '?auth=callback&error=access_denied&error_description=LOCAL_UNSAFE',
    '?auth=callback',
    '?auth=callback&access_token=incomplete',
    '?auth=callback&code=missing-verifier',
    '?auth=callback&code=%FF',
    '?auth=callback#error_description=%FF',
    '?%61uth=callback&code=%C0%AF',
  ]) {
    test(
      'unsuccessful callback preserves the existing session and returns a static result: $suffix',
      () async {
        var requests = 0;
        final client = SupabaseClient(
          'https://local.invalid',
          'local-key',
          httpClient: MockClient((_) async {
            requests++;
            return http.Response('{}', 400);
          }),
          isolate: _Json(),
          authOptions: AuthClientOptions(
            autoRefreshToken: false,
            pkceAsyncStorage: _Storage(),
          ),
        );
        try {
          await client.auth.setInitialSession(jsonEncode(_session(_user)));
          final previous = client.auth.currentSession;
          final uri = Uri.parse('https://app.invalid/$suffix');
          expect(
            await completeAuthCallback(client, uri),
            AuthCallbackResult.failed,
          );
          expect(identical(client.auth.currentSession, previous), isTrue);
          expect(client.auth.currentUser?.id, _user);
          expect(requests, 0);
          final clean = withoutAuthCallbackParameters(uri);
          expect(isAuthCallback(clean), isFalse);
          expect(clean.toString(), isNot(contains('LOCAL_UNSAFE')));
        } finally {
          await client.dispose();
        }
      },
    );
  }

  test(
    'successful PKCE uses one SDK exchange; a spent code fails without replacing the session',
    () async {
      final storage = _Storage()
        ..values['supabase.auth.token-code-verifier'] = 'local-verifier';
      var exchanges = 0;
      final client = SupabaseClient(
        'https://local.invalid',
        'local-key',
        isolate: _Json(),
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: storage,
        ),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/auth/v1/token');
          expect(request.url.queryParameters['grant_type'], 'pkce');
          expect(jsonDecode(request.body), {
            'auth_code': 'local-code',
            'code_verifier': 'local-verifier',
          });
          exchanges++;
          return http.Response(
            jsonEncode(_session(_other)),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      try {
        final uri = Uri.parse(
          'https://app.invalid/?auth=callback&code=local-code',
        );
        expect(
          await completeAuthCallback(client, uri),
          AuthCallbackResult.succeeded,
        );
        expect(exchanges, 1);
        expect(client.auth.currentUser?.id, _other);
        final accepted = client.auth.currentSession;
        expect(
          await completeAuthCallback(client, uri),
          AuthCallbackResult.failed,
        );
        expect(exchanges, 1);
        expect(identical(client.auth.currentSession, accepted), isTrue);
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'server-rejected PKCE preserves a prior identity without a successful callback',
    () async {
      final storage = _Storage()
        ..values['supabase.auth.token-code-verifier'] = 'local-verifier';
      var exchanges = 0;
      final client = SupabaseClient(
        'https://local.invalid',
        'local-key',
        isolate: _Json(),
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: storage,
        ),
        httpClient: MockClient((request) async {
          exchanges++;
          return http.Response(
            '{"error":"invalid_grant","error_description":"LOCAL_UNSAFE"}',
            400,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      try {
        await client.auth.setInitialSession(jsonEncode(_session(_user)));
        final prior = client.auth.currentSession;
        expect(
          await completeAuthCallback(
            client,
            Uri.parse('https://app.invalid/?auth=callback&code=spent'),
          ),
          AuthCallbackResult.failed,
        );
        expect(exchanges, 1);
        expect(identical(client.auth.currentSession, prior), isTrue);
      } finally {
        await client.dispose();
      }
    },
  );

  test('implicit callback restores through SDK getUser once', () async {
    var lookups = 0;
    final client = SupabaseClient(
      'https://local.invalid',
      'local-key',
      isolate: _Json(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        expect(request.url.path, '/auth/v1/user');
        lookups++;
        return http.Response(
          jsonEncode(_session(_user)['user']),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    try {
      final uri = Uri.parse('https://app.invalid/?auth=callback').replace(
        fragment: Uri(
          queryParameters: {
            'access_token': token(_user),
            'refresh_token': 'local-refresh',
            'expires_in': '3600',
            'token_type': 'bearer',
          },
        ).query,
      );
      expect(
        await completeAuthCallback(client, uri),
        AuthCallbackResult.succeeded,
      );
      expect(lookups, 1);
      expect(client.auth.currentUser?.id, _user);
    } finally {
      await client.dispose();
    }
  });

  test(
    'URL cleanup strips auth secrets and keeps repeated unrelated query values and invitation',
    () {
      final uri = Uri.parse(
        'https://app.invalid/path?auth=callback&code=local-code&keep=1&keep=2&otp=local'
        '#error=access_denied&error_description=LOCAL_UNSAFE&refresh_token=local&invite=local-invite',
      );
      final clean = withoutAuthCallbackParameters(uri);
      expect(clean.queryParametersAll, {
        'keep': ['1', '2'],
      });
      expect(clean.fragment, 'invite=local-invite');
      expect(isAuthCallback(clean), isFalse);
    },
  );
}
