import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/avatar_upload.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'live_chat_api_test.dart' show token;

const a = '73000000-0000-4000-8000-000000000001';
const b = '73000000-0000-4000-8000-000000000002';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'normal',
    'begin failure',
    'switch before upload',
    'switch during upload',
    'upload failure',
    'same user new session',
    'same session refresh',
    'same user switch during upload',
  ]) {
    test(
      'avatar lifecycle $mode protects operation identity and fresh retry paths',
      () async {
        final requests = <http.Request>[];
        final begin = Completer<http.Response>(),
            upload = Completer<http.Response>(),
            reached = Completer<void>();
        var signIns = 0;
        final transport = MockClient((r) async {
          if (r.url.path.endsWith('/token')) {
            final id =
                (jsonDecode(r.body) as Map)['email'] == 'a@example.invalid'
                ? a
                : b;
            signIns++;
            var credential = token(id);
            if (mode.startsWith('same')) {
              final claims =
                  jsonDecode(
                        utf8.decode(
                          base64Url.decode(
                            base64Url.normalize(credential.split('.')[1]),
                          ),
                        ),
                      )
                      as Map;
              claims['session_id'] =
                  mode == 'same session refresh' || signIns == 1
                  ? '73000000-0000-4000-8000-000000000003'
                  : '73000000-0000-4000-8000-000000000004';
              claims['iat'] = signIns;
              credential =
                  'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature';
            }
            return http.Response(
              jsonEncode({
                'access_token': credential,
                'refresh_token': 'test-only',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': id,
                  'aud': 'authenticated',
                  'created_at': '2026-01-01T00:00:00Z',
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
              200,
            );
          }
          requests.add(r);
          if (r.url.path.endsWith('/avatar_upload_begin')) {
            if (mode == 'begin failure') {
              return http.Response(
                '{"message":"session_revoked","code":"42501"}',
                400,
                headers: {'content-type': 'application/json'},
              );
            }
            if (mode == 'switch before upload' ||
                mode == 'same user new session' ||
                mode == 'same session refresh') {
              reached.complete();
              return begin.future;
            }
            return http.Response(
              'null',
              200,
              request: r,
              headers: {'content-type': 'application/json'},
            );
          }
          if (mode == 'switch during upload' ||
              mode == 'same user switch during upload') {
            reached.complete();
            return upload.future;
          }
          if (mode == 'upload failure') {
            return http.Response('{"message":"unavailable"}', 503);
          }
          return http.Response('{"Key":"ok"}', 200);
        });
        final client = SupabaseClient(
          'https://photo-test.invalid',
          'test-key',
          httpClient: transport,
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        try {
          await client.auth.signInWithPassword(
            email: 'a@example.invalid',
            password: 'test-only',
          );
          final photo = Uint8List.fromList([137, 80, 78, 71]);
          if (mode == 'normal') {
            final first = await uploadAvatar(client, a, photo),
                second = await uploadAvatar(client, a, photo);
            expect(first, isNot(second));
            expect(first, matches(RegExp('^$a/[a-f0-9]{64}[.]png\$')));
            expect(
              requests.map((r) => r.url.path.contains('avatar_upload_begin')),
              [true, false, true, false],
            );
            expect((jsonDecode(requests.first.body) as Map)['p_path'], first);
            expect(requests[1].headers['x-upsert'], 'false');
          } else if (mode.startsWith('switch') || mode.startsWith('same')) {
            final pending = uploadAvatar(client, a, photo);
            await reached.future;
            await client.auth.signInWithPassword(
              email: mode.startsWith('same')
                  ? 'a@example.invalid'
                  : 'b@example.invalid',
              password: 'test-only',
            );
            final rejected = expectLater(
              pending,
              mode == 'same session refresh'
                  ? completes
                  : throwsA(isA<AuthException>()),
            );
            if (mode == 'switch before upload' ||
                mode == 'same user new session' ||
                mode == 'same session refresh') {
              begin.complete(
                http.Response(
                  'null',
                  200,
                  request: requests.first,
                  headers: {'content-type': 'application/json'},
                ),
              );
            } else {
              upload.complete(http.Response('{"Key":"ok"}', 200));
            }
            await rejected;
            if (mode == 'switch before upload' ||
                mode == 'same user new session') {
              expect(requests.length, 1);
            }
            if (mode == 'same session refresh') expect(requests.length, 2);
          } else {
            await expectLater(
              uploadAvatar(client, a, photo),
              throwsA(anything),
            );
            if (mode == 'begin failure') {
              expect(requests.length, 1);
            } else {
              await expectLater(
                uploadAvatar(client, a, photo),
                throwsA(anything),
              );
              expect(
                (jsonDecode(requests[0].body) as Map)['p_path'],
                isNot((jsonDecode(requests[2].body) as Map)['p_path']),
              );
            }
          }
        } finally {
          await client.dispose();
        }
      },
    );
  }
}
