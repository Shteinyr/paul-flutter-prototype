import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/platform/notifications/native_push_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

const actor = '15000000-0000-4000-8000-000000000001';
const other = '15000000-0000-4000-8000-000000000002';
const session = '15100000-0000-4000-8000-000000000001';
const laterSession = '15100000-0000-4000-8000-000000000002';
const proposed = '15200000-0000-4000-8000-000000000001';
const canonical = '15200000-0000-4000-8000-000000000002';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

void main() {
  for (final scenario in [
    'valid',
    'wrong-owner',
    'wrong-session',
    'invalid-id',
    'session-switch',
  ]) {
    test(
      'native API $scenario validates session-bound registration before accepting the binding',
      () async {
        final reached = Completer<void>();
        final response = Completer<http.Response>();
        final requests = <http.Request>[];
        final tokens = <String, String>{};
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            final body = jsonDecode(request.body) as Map;
            final id = body['email'] == 'later@example.invalid'
                ? laterSession
                : session;
            final token =
                'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': actor, 'session_id': id, 'aud': 'authenticated', 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.signature';
            tokens[id] = token;
            return http.Response(
              jsonEncode({
                'access_token': token,
                'refresh_token': 'test-only',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': actor,
                  'aud': 'authenticated',
                  'created_at': DateTime.utc(2026).toIso8601String(),
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
              200,
            );
          }
          requests.add(request);
          expect(request.url.path, '/functions/v1/native-push');
          if (scenario == 'session-switch') {
            reached.complete();
            return response.future;
          }
          return http.Response(
            jsonEncode({
              'recipient_user_id': scenario == 'wrong-owner' ? other : actor,
              'session_id': scenario == 'wrong-session'
                  ? laterSession
                  : session,
              'binding_id': scenario == 'invalid-id' ? 'invalid' : canonical,
              'enabled': true,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        addTearDown(client.dispose);
        await client.auth.signInWithPassword(
          email: 'qa@example.invalid',
          password: 'test-only',
        );
        final api = SupabaseNativePushApi(client, actor, session);
        final result = api.subscribe(
          proposed,
          'fid-installation-id-123',
          'ios',
        );
        if (scenario == 'valid') {
          expect(await result, canonical);
        } else {
          final rejected = expectLater(
            result,
            throwsA(isA<NativePushRequestException>()),
          );
          if (scenario == 'session-switch') {
            await reached.future;
            await client.auth.signInWithPassword(
              email: 'later@example.invalid',
              password: 'test-only',
            );
            response.complete(
              http.Response(
                jsonEncode({
                  'recipient_user_id': actor,
                  'session_id': session,
                  'binding_id': canonical,
                  'enabled': true,
                }),
                200,
                headers: {'content-type': 'application/json'},
              ),
            );
          }
          await rejected;
        }
        expect(requests, hasLength(1));
        expect(
          requests.single.headers['authorization'],
          'Bearer ${tokens[session]}',
        );
        expect(jsonDecode(requests.single.body), {
          'action': 'subscribe',
          'binding_id': proposed,
          'token': 'fid-installation-id-123',
          'platform': 'ios',
        });
        if (scenario == 'session-switch') {
          await expectLater(
            api.unsubscribe(proposed),
            throwsA(isA<NativePushRequestException>()),
          );
          expect(requests, hasLength(1));
        }
      },
    );
  }
}
