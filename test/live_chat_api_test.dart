import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/admin/operator_chat_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

String token(String id) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': id, 'aud': 'authenticated', 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.signature';

void main() {
  for (final outcome in ['success', 'forbidden', 'identity-change']) {
    test(
      'operator peer photo respects Storage authorization: $outcome',
      () async {
        const actor = '10000000-0000-4000-8000-000000000001';
        const other = '10000000-0000-4000-8000-000000000002';
        final response = Completer<http.Response>();
        final reached = Completer<void>();
        var downloads = 0;
        String? authorization;
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            final id =
                (jsonDecode(request.body) as Map)['email'] ==
                    'actor@example.invalid'
                ? actor
                : other;
            return http.Response(
              jsonEncode({
                'access_token': token(id),
                'refresh_token': 'local-only',
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
          expect(request.method, 'GET');
          expect(
            request.url.path,
            '/storage/v1/object/avatars/peer/saved.png',
          );
          authorization = request.headers['authorization'];
          downloads++;
          reached.complete();
          return response.future;
        });
        final client = SupabaseClient(
          'https://operator-test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        final repository = OperatorChatApi(
          SupabaseAdminApi(client, actor),
          'managed',
        );
        try {
          await client.auth.signInWithPassword(
            email: 'actor@example.invalid',
            password: 'test-only',
          );
          final originalToken = client.auth.currentSession!.accessToken;
          expect(
            await repository.photo(
              ChatPeer(
                id: 'deleted',
                name: '',
                occupation: '',
                avatarPath: 'peer/saved.png',
                deletedAt: DateTime.utc(2026),
              ),
            ),
            isNull,
          );
          expect(downloads, 0);
          const peer = ChatPeer(
            id: 'peer',
            name: 'Peer',
            occupation: '',
            avatarPath: 'peer/saved.png',
          );
          final operation = repository.photo(peer);
          final assertion = expectLater(
            operation,
            outcome == 'success'
                ? completion(orderedEquals([1, 2, 3]))
                : throwsA(
                    outcome == 'forbidden'
                        ? isA<StorageException>()
                        : isA<ChatException>(),
                  ),
          );
          await reached.future;
          expect(authorization, 'Bearer $originalToken');
          if (outcome == 'identity-change') {
            await client.auth.signInWithPassword(
              email: 'other@example.invalid',
              password: 'test-only',
            );
          }
          response.complete(
            outcome == 'forbidden'
                ? http.Response(
                    '{"message":"Denied","statusCode":"403"}',
                    403,
                    headers: {'content-type': 'application/json'},
                  )
                : http.Response.bytes(
                    [1, 2, 3],
                    200,
                    headers: {'content-type': 'image/png'},
                  ),
          );
          await assertion;
          expect(downloads, 1);
          if (outcome == 'identity-change') {
            await expectLater(
              repository.photo(peer),
              throwsA(isA<ChatException>()),
            );
            expect(downloads, 1);
          }
        } finally {
          await repository.dispose();
          await client.dispose();
        }
      },
    );
  }

  test(
    'delayed transport pins initiating authorization and rejects response after account switch',
    () async {
      const a = '10000000-0000-4000-8000-000000000001';
      const b = '10000000-0000-4000-8000-000000000002';
      final response = Completer<http.Response>();
      final reachedTransport = Completer<void>();
      String? authorization;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          final id =
              (jsonDecode(request.body) as Map)['email'] == 'a@example.invalid'
              ? a
              : b;
          return http.Response(
            jsonEncode({
              'access_token': token(id),
              'refresh_token': 'test-only-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': id,
                'aud': 'authenticated',
                'created_at': DateTime.utc(2026).toIso8601String(),
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
          );
        }
        authorization = request.headers['authorization'];
        reachedTransport.complete();
        return response.future;
      });
      final client = SupabaseClient(
        'https://chat-test.invalid',
        'test-key',
        httpClient: transport,
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      try {
        await client.auth.signInWithPassword(
          email: 'a@example.invalid',
          password: 'test-only',
        );
        final originalToken = client.auth.currentSession!.accessToken;
        final operation = SupabaseChatApi(
          client,
          a,
        ).send('chat', 'client-id', 'A private text');
        // The HTTP auth adapter awaits its access-token provider. Account B may
        // become current while this request is preparing or waiting for a reply.
        await client.auth.signInWithPassword(
          email: 'b@example.invalid',
          password: 'test-only',
        );
        await reachedTransport.future;
        expect(authorization, 'Bearer $originalToken');
        final rejection = expectLater(
          operation,
          throwsA(
            isA<ChatException>().having(
              (error) => error.code,
              'code',
              'sign_in_required',
            ),
          ),
        );
        response.complete(
          http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await rejection;
        await expectLater(
          SupabaseChatApi(client, a).list(),
          throwsA(isA<ChatException>()),
        );
      } finally {
        await client.dispose();
      }
    },
  );
  test(
    'operator grant loss invalidates private UI identity while Auth remains the real actor',
    () async {
      const actor = '10000000-0000-4000-8000-000000000001';
      const managed = '10000000-0000-4000-8000-000000000002';
      var denied = false;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token': token(actor),
              'refresh_token': 'test-only-refresh',
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
        final body = jsonDecode(request.body) as Map;
        expect(body['profile_id'], managed);
        expect(body['action'], 'inbox');
        expect(body.containsKey('actor_user_id'), false);
        return http.Response(
          jsonEncode(
            denied
                ? {'code': 'managed_profile_forbidden'}
                : {'conversations': []},
          ),
          denied ? 403 : 200,
          headers: {'Content-Type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://admin-test.invalid',
        'test-key',
        httpClient: transport,
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.signInWithPassword(
        email: 'qa@example.invalid',
        password: 'test-only',
      );
      final repository = OperatorChatApi(
        SupabaseAdminApi(client, actor),
        managed,
      );
      final identities = <String?>[];
      final subscription = repository.identityChanges.listen(identities.add);
      try {
        expect(await repository.list(), isEmpty);
        denied = true;
        await expectLater(repository.list(), throwsA(isA<ChatException>()));
        await Future<void>.delayed(Duration.zero);
        expect(repository.currentUserId, null);
        expect(identities.last, null);
        expect(client.auth.currentUser!.id, actor);
      } finally {
        await subscription.cancel();
        await repository.dispose();
        await client.dispose();
      }
    },
  );
}
