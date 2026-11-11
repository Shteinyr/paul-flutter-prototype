import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'live_chat_api_test.dart' show token;

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

void main() {
  for (final scenario in ['roundtrip', 'locked', 'identity-change']) {
    test(
      'Community API $scenario keeps captured identity and contract',
      () async {
        const actor = '10000000-0000-4000-8000-000000000001';
        const later = '10000000-0000-4000-8000-000000000002';
        const requestId = '10000000-0000-4000-8000-000000000003';
        const operation = '10000000-0000-4000-8000-000000000004';
        final calls = <Map>[];
        final reached = Completer<void>();
        final pending = Completer<http.Response>();
        final item = {
          'id': requestId,
          'author': {
            'id': later,
            'name': 'Author',
            'occupation': '',
            'avatar_path': null,
          },
          'skill': 'Design',
          'message': 'Please help',
          'is_author': false,
          'created_at': '2026-11-11T00:00:00Z',
          'expires_at': '2026-12-11T00:00:00Z',
        };
        final transport = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          Object data;
          if (request.url.path.endsWith('/token')) {
            final id = body['email'] == 'later@example.invalid' ? later : actor;
            data = {
              'access_token': token(id),
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
            };
          } else {
            calls.add(body);
            expect(request.headers['authorization'], 'Bearer ${token(actor)}');
            if (scenario == 'identity-change') {
              reached.complete();
              return pending.future;
            }
            if (scenario == 'locked') {
              return http.Response(
                jsonEncode({'code': 'community_locked'}),
                403,
                headers: {'content-type': 'application/json'},
              );
            }
            data = switch (body['action']) {
              'feed' => {
                'requests': [item],
                'next_cursor': {
                  'id': requestId,
                  'created_at': item['created_at'],
                },
                'server_now': '2026-11-11T01:00:00Z',
              },
              'get' => {'request': item},
              'create' => {'request_id': requestId, 'state': 'active'},
              'close' => {'request_id': requestId, 'state': 'unavailable'},
              'capabilities' => {
                'invited_registrations': 10,
                'can_message_anyone': true,
                'can_publish_community': true,
                'offering_limit': null,
                'new_conversations_remaining': null,
                'quota_resets_at': '2026-11-12T00:00:00Z',
              },
              _ => throw StateError('Unexpected Community call'),
            };
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://community-test.invalid',
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
          final api = SupabaseCommunityApi(client, actor);
          if (scenario == 'roundtrip') {
            final page = await api.feed();
            expect(page.requests.single.id, requestId);
            expect(page.requests.single.author.id, later);
            expect(page.serverNow, DateTime.utc(2026, 11, 11, 1));
            await api.feed(cursor: page.nextCursor);
            expect(calls[1]['cursor'], page.nextCursor);
            final detail = await api.get(requestId);
            expect(detail?.message, 'Please help');
            expect(await api.photo(detail!), isNull);
            expect(
              (await api.create(operation, 'Design', 'Please help')).active,
              isTrue,
            );
            expect(calls.last, {
              'action': 'create',
              'client_operation_id': operation,
              'skill': 'Design',
              'message': 'Please help',
            });
            await api.close(operation, requestId);
            expect(calls.last, {
              'action': 'close',
              'client_operation_id': operation,
              'request_id': requestId,
            });
            expect((await api.capabilities()).canPublishCommunity, isTrue);
          } else if (scenario == 'locked') {
            await expectLater(
              api.create(operation, 'Design', 'Please help'),
              throwsA(
                isA<CommunityException>().having(
                  (error) => error.code,
                  'code',
                  'community_locked',
                ),
              ),
            );
          } else {
            final result = api.feed();
            final rejected = expectLater(
              result,
              throwsA(
                isA<CommunityException>().having(
                  (error) => error.code,
                  'code',
                  'sign_in_required',
                ),
              ),
            );
            await reached.future;
            await client.auth.signInWithPassword(
              email: 'later@example.invalid',
              password: 'test-only',
            );
            pending.complete(
              http.Response(
                jsonEncode({
                  'requests': [item],
                  'next_cursor': null,
                  'server_now': '2026-11-11T01:00:00Z',
                }),
                200,
                headers: {'content-type': 'application/json'},
              ),
            );
            await rejected;
            await expectLater(
              api.get(requestId),
              throwsA(isA<CommunityException>()),
            );
            expect(calls, hasLength(1));
          }
        } finally {
          await client.dispose();
        }
      },
    );
  }
}
