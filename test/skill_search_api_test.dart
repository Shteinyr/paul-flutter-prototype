import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/search/skill_search_api.dart';
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'remote and catalogue MAR suggestions retain common marketing priority',
    () async {
      const userId = '10000000-0000-4000-8000-000000000001';
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token': token(userId),
              'refresh_token': 'test-only',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': userId,
                'aud': 'authenticated',
                'created_at': DateTime.utc(2026).toIso8601String(),
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
          );
        }
        expect(request.url.path, '/functions/v1/skill-search');
        expect((jsonDecode(request.body) as Map)['query'], 'MAR');
        return http.Response(
          jsonEncode({
            'suggestions': [
              {'key': 'marathi', 'label': 'Marathi'},
              {'key': 'marklogic', 'label': 'MarkLogic'},
              {'key': 'digital marketing', 'label': 'DIGITAL MARKETING'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://search-test.invalid',
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
        final items = await SupabaseSkillSearchApi(
          client,
          userId,
        ).suggest('MAR', SkillSearchKind.all);
        expect(items.take(3).map((item) => item.key), [
          'marketing',
          'content marketing',
          'digital marketing',
        ]);
        expect(items[2].label, 'DIGITAL MARKETING');
        expect(
          items.where((item) => item.key == 'digital marketing'),
          hasLength(1),
        );
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'search pins initiating JWT and rejects late response after identity switch',
    () async {
      const a = '10000000-0000-4000-8000-000000000001';
      const b = '10000000-0000-4000-8000-000000000002';
      final pending = Completer<http.Response>();
      final reached = Completer<void>();
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
              'refresh_token': 'test-only',
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
        reached.complete();
        return pending.future;
      });
      final client = SupabaseClient(
        'https://search-test.invalid',
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
        final initiatingToken = client.auth.currentSession!.accessToken;
        final api = SupabaseSkillSearchApi(client, a);
        final operation = api.search('Marketing', SkillSearchKind.all);
        await client.auth.signInWithPassword(
          email: 'b@example.invalid',
          password: 'test-only',
        );
        await reached.future;
        expect(authorization, 'Bearer $initiatingToken');
        final rejection = expectLater(
          operation,
          throwsA(
            isA<SkillSearchException>().having(
              (error) => error.code,
              'code',
              'sign_in_required',
            ),
          ),
        );
        pending.complete(
          http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await rejection;
        await expectLater(
          api.suggest('mar', SkillSearchKind.all),
          throwsA(isA<SkillSearchException>()),
        );
      } finally {
        await client.dispose();
      }
    },
  );
  test(
    'name capability sends separate action with all kind and preserves cursor',
    () async {
      const id = '10000000-0000-4000-8000-000000000001';
      final cursor = {'query': 'julia', 'mode': 'names', 'after': 'one'};
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          return http.Response(
            jsonEncode({
              'access_token': token(id),
              'refresh_token': 'test-only',
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
        expect(request.url.path, '/functions/v1/skill-search');
        expect(jsonDecode(request.body), {
          'action': 'search_names',
          'query': 'Julia',
          'kind': 'all',
          'cursor': cursor,
        });
        return http.Response(
          jsonEncode({
            'query': 'julia',
            'kind': 'all',
            'results': [
              {
                'id': id,
                'name': 'Julia',
                'occupation': 'Designer',
                'matched_kinds': [],
              },
            ],
            'next_cursor': null,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://search-test.invalid',
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
        final result = await SupabaseSkillSearchApi(
          client,
          id,
        ).searchNames('Julia', cursor: cursor);
        expect(result.results.single.name, 'Julia');
        expect(result.results.single.matchedKinds, isEmpty);
        expect(result.nextCursor, isNull);
      } finally {
        await client.dispose();
      }
    },
  );
}
