import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/contacts/phone_discovery_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'deletion_controller_test.dart' show actor, other;
import 'live_chat_api_test.dart' show token;

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

Map<String, dynamic> _session(
  String id,
  String refresh, {
  bool verified = false,
}) => {
  'access_token': token(id),
  'refresh_token': refresh,
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': id,
    'aud': 'authenticated',
    'created_at': '2026-01-01T00:00:00Z',
    'app_metadata': {},
    'user_metadata': {},
    if (verified) 'phone': '12025550123',
    if (verified) 'phone_confirmed_at': '2026-11-11T00:00:00Z',
  },
};

void main() {
  for (final scenario in [
    'normal',
    'late-other-user',
    'late-same-user-session',
    'sms-disabled',
  ]) {
    test(
      'real SDK phone-change $scenario keeps the current identity fenced',
      () async {
        final pending = Completer<http.Response>();
        final reached = Completer<void>();
        var verifyCalls = 0;
        var updateCalls = 0;
        String? verificationAuthorization;
        final transport = MockClient((request) async {
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Map;
          Object data;
          if (request.url.path.endsWith('/token')) {
            final later = body['email'] == 'later@example.invalid';
            data = _session(
              later && scenario == 'late-other-user' ? other : actor,
              later ? 'later-refresh' : 'original-refresh',
            );
          } else if (request.url.path.endsWith('/settings')) {
            data = {
              'external': {'phone': scenario != 'sms-disabled'},
            };
          } else if (request.url.path.endsWith('/user')) {
            updateCalls++;
            expect(request.method, 'PUT');
            expect(body, {'phone': '+12025550123'});
            data = _session(actor, 'original-refresh')['user']!;
          } else if (request.url.path.endsWith('/verify')) {
            verifyCalls++;
            expect(body, {
              'phone': '+12025550123',
              'token': '123456',
              'type': 'phone_change',
            });
            verificationAuthorization = request.headers['authorization'];
            if (scenario.startsWith('late')) {
              reached.complete();
              return pending.future;
            }
            data = _session(actor, 'verified-refresh', verified: true);
          } else {
            throw StateError('Unexpected phone Auth request');
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://phone-test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        final api = SupabasePhoneDiscoveryApi(
          client,
          actor,
          url: 'https://phone-test.invalid',
          key: 'test-key',
          authTransport: transport,
        );
        try {
          await client.auth.signInWithPassword(
            email: 'qa@example.invalid',
            password: 'test-only',
          );
          if (scenario == 'sms-disabled') {
            await expectLater(
              api.requestCode('+12025550123'),
              throwsA(
                isA<PhoneDiscoveryException>().having(
                  (error) => error.code,
                  'code',
                  'sms_unavailable',
                ),
              ),
            );
            expect(updateCalls, 0);
            expect(verifyCalls, 0);
            expect(client.auth.currentUser?.id, actor);
            return;
          }
          await api.requestCode('+12025550123');
          final verifying = api.verifyCode('+12025550123', '123456');
          Future<void>? rejected;
          if (scenario == 'late-other-user') {
            rejected = expectLater(
              verifying,
              throwsA(
                isA<PhoneDiscoveryException>().having(
                  (error) => error.code,
                  'code',
                  'identity_changed',
                ),
              ),
            );
          }
          if (scenario.startsWith('late')) {
            await reached.future;
            await client.auth.signInWithPassword(
              email: 'later@example.invalid',
              password: 'test-only',
            );
            pending.complete(
              http.Response(
                jsonEncode(_session(actor, 'verified-refresh', verified: true)),
                200,
                headers: {'content-type': 'application/json'},
              ),
            );
          }
          if (rejected != null) {
            await rejected;
            expect(client.auth.currentUser?.id, other);
            expect(client.auth.currentSession?.refreshToken, 'later-refresh');
          } else {
            expect(await verifying, isTrue);
            expect(client.auth.currentUser?.id, actor);
            expect(
              client.auth.currentSession?.refreshToken,
              scenario == 'normal' ? 'verified-refresh' : 'later-refresh',
            );
          }
          expect(verificationAuthorization, 'Bearer ${token(actor)}');
          expect(verifyCalls, 1);
        } finally {
          api.dispose();
          await client.dispose();
        }
      },
    );
  }

  testWidgets(
    'phone verification times out when headers arrive but body stalls',
    (tester) async {
      final sdkTransport = MockClient(
        (_) async => http.Response(
          jsonEncode(_session(actor, 'original-refresh')),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final body = StreamController<List<int>>();
      final reached = Completer<void>();
      final authTransport = MockClient.streaming((_, _) async {
        reached.complete();
        return http.StreamedResponse(
          body.stream,
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://phone-test.invalid',
        'test-key',
        httpClient: sdkTransport,
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final api = SupabasePhoneDiscoveryApi(
        client,
        actor,
        url: 'https://phone-test.invalid',
        key: 'test-key',
        authTransport: authTransport,
      );
      try {
        await client.auth.signInWithPassword(
          email: 'qa@example.invalid',
          password: 'test-only',
        );
        final verifying = api.verifyCode('+12025550123', '123456');
        final timedOut = expectLater(
          verifying,
          throwsA(isA<TimeoutException>()),
        );
        await reached.future;
        await tester.pump(const Duration(seconds: 26));
        await timedOut;
        expect(client.auth.currentUser?.id, actor);
      } finally {
        await body.close();
        api.dispose();
        await tester.runAsync(client.dispose);
      }
    },
  );

  test(
    'phone discovery sends both consent fences and preserves source indexes',
    () async {
      const consentRevision = '10000000-0000-4000-8000-000000000003';
      final calls = <Map>[];
      final transport = MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        Object data;
        if (request.url.path.endsWith('/token')) {
          data = _session(actor, 'original-refresh');
        } else {
          calls.add(body);
          expect(body['expected_user_id'], actor);
          data = body['action'] == 'lookup'
              ? {
                  'matches': [
                    {'index': 1, 'profile_id': other},
                  ],
                  'invalid_indexes': [0],
                }
              : {
                  'has_verified_phone': true,
                  'discoverable': body['enabled'] == true,
                  'phone_last4': '0123',
                  'phone_revision': List.filled(64, 'a').join(),
                  'consent_revision': consentRevision,
                };
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://phone-test.invalid',
        'test-key',
        httpClient: transport,
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final api = SupabasePhoneDiscoveryApi(
        client,
        actor,
        url: 'https://phone-test.invalid',
        key: 'test-key',
        authTransport: transport,
      );
      try {
        await client.auth.signInWithPassword(
          email: 'qa@example.invalid',
          password: 'test-only',
        );
        final status = await api.status();
        await api.consent(true, status);
        expect(calls.last['expected_consent_revision'], consentRevision);
        expect(calls.last['expected_phone_revision'], status.phoneRevision);
        await api.consent(false, status);
        expect(calls.last['expected_consent_revision'], consentRevision);
        expect(calls.last.containsKey('expected_phone_revision'), isFalse);
        final result = await api.lookup(['invalid', '+12025550123'], 'US');
        expect(result.matches, {1: other});
        expect(result.invalid, {0});
        expect(calls.last['phones'], ['invalid', '+12025550123']);
        expect(calls.last['default_country'], 'US');
      } finally {
        api.dispose();
        await client.dispose();
      }
    },
  );
}
