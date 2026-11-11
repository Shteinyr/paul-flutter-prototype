import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/push/push_api.dart';
import 'package:paul_demo/push/push_browser_types.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';
import 'push_controller_test.dart' show user, session, proposed, canonical;

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

void main() {
  for (final scenario in [
    'canonical',
    'wrong-recipient',
    'invalid-operator',
    'changed-session',
    'community-active',
    'community-unavailable',
    'community-invalid',
  ]) {
    test(
      'push API $scenario checks pinned identity and DTO before exposing a route',
      () async {
        const laterSession = '30000000-0000-4000-8000-000000000001';
        final pending = Completer<http.Response>();
        final reached = Completer<void>();
        String? authorization;
        final requests = <Map>[];
        final tokens = <String, String>{};
        final transport = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          if (request.url.path.endsWith('/token')) {
            final id = body['email'] == 'later@example.invalid'
                ? laterSession
                : session;
            final token =
                'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': user, 'session_id': id, 'aud': 'authenticated', 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.signature';
            tokens[id] = token;
            return http.Response(
              jsonEncode({
                'access_token': token,
                'refresh_token': 'test-only',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': user,
                  'aud': 'authenticated',
                  'created_at': DateTime.utc(2026).toIso8601String(),
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
              200,
            );
          }
          requests.add(body);
          authorization = request.headers['authorization'];
          if (scenario == 'changed-session') {
            reached.complete();
            return pending.future;
          }
          final data = scenario.startsWith('community-')
              ? {
                  'kind': 'community',
                  'request_id': canonical,
                  'state': scenario.substring(10),
                }
              : body['action'] == 'subscribe'
              ? {
                  'binding_id': canonical,
                  'recipient_user_id': scenario == 'wrong-recipient'
                      ? proposed
                      : user,
                  'enabled': true,
                }
              : {
                  'kind': 'operator',
                  'conversation_id': canonical,
                  'managed_profile_id': 'not-a-uuid',
                };
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://push-test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        try {
          await client.auth.signInWithPassword(
            email: 'qa@example.invalid',
            password: 'test-only',
          );
          expect(pushSessionId(client), session);
          final api = SupabasePushApi(client, user, session);
          if (scenario == 'changed-session') {
            final response = api.config();
            final rejected = expectLater(
              response,
              throwsA(isA<PushException>()),
            );
            await reached.future;
            await client.auth.signInWithPassword(
              email: 'later@example.invalid',
              password: 'test-only',
            );
            pending.complete(
              http.Response(
                jsonEncode({
                  'version': 1,
                  'enabled': true,
                  'vapid_public_key': 'public-test-key',
                }),
                200,
              ),
            );
            await rejected;
            expect(authorization, 'Bearer ${tokens[session]}');
            expect(api.current, isFalse);
          } else if (scenario.startsWith('community-')) {
            final route = api.resolve(
              const PushClick(user, canonical, proposed),
            );
            if (scenario == 'community-invalid') {
              await expectLater(route, throwsA(isA<PushException>()));
            } else {
              final result = await route;
              expect(result.kind, 'community');
              expect(result.requestId, canonical);
              expect(result.requestState, scenario.substring(10));
            }
          } else if (scenario == 'invalid-operator') {
            await expectLater(
              api.resolve(const PushClick(user, canonical, proposed)),
              throwsA(isA<PushException>()),
            );
            expect(requests.single, {
              'action': 'resolve',
              'delivery_id': proposed,
              'binding_id': canonical,
            });
          } else {
            final result = api.subscribe(
              const PreparedPush(proposed, {'endpoint': 'synthetic'}),
            );
            if (scenario == 'canonical') {
              expect(await result, canonical);
            } else {
              await expectLater(result, throwsA(isA<PushException>()));
            }
            expect(requests.single['binding_id'], proposed);
            expect(authorization, 'Bearer ${tokens[session]}');
          }
        } finally {
          await client.dispose();
        }
      },
    );
  }
}
