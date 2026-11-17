import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/live_api.dart';
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
  for (final endpoint in ['network', 'profile']) {
    test('late $endpoint cannot restore a confirmed deleted profile', () async {
      const actor = '10000000-0000-4000-8000-000000000001';
      const peer = '10000000-0000-4000-8000-000000000002';
      final gate = Completer<http.Response>();
      final started = Completer<void>();
      Map<String, dynamic> profile(String id) => {
        'id': id,
        'name': id == actor ? 'Viewer' : 'Peer',
        'occupation': 'Designer',
        'summary': '',
        'skills': ['Design'],
        'searching_skills': [],
        'contact_count': 1,
        'avatar_path': '$id/v1.png',
      };
      final client = SupabaseClient(
        'https://media.invalid',
        'test-only',
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            return http.Response(
              jsonEncode({
                'access_token': token(actor),
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
              headers: {'content-type': 'application/json'},
            );
          }
          started.complete();
          return gate.future;
        }),
      );
      try {
        await client.auth.signInWithPassword(
          email: 'qa@example.invalid',
          password: 'test-only',
        );
        final api = LiveApi(client);
        if (endpoint == 'network') {
          final pending = api.network();
          await started.future;
          api.forgetMember(peer);
          gate.complete(
            http.Response(
              jsonEncode({
                'profile': profile(actor),
                'contacts': [profile(peer)],
              }),
              200,
              headers: {'content-type': 'application/json'},
            ),
          );
          expect((await pending).contacts, isEmpty);
        } else {
          final pending = api.member(peer);
          final assertion = expectLater(
            pending,
            throwsA(isA<LiveApiException>()),
          );
          await started.future;
          api.forgetMember(peer);
          gate.complete(
            http.Response(
              jsonEncode({'profile': profile(peer)}),
              200,
              headers: {'content-type': 'application/json'},
            ),
          );
          await assertion;
        }
        expect(api.cachedMember(peer), isNull);
        expect(api.cachedPhoto(peer, '$peer/v1.png'), isNull);
      } finally {
        await client.dispose();
      }
    });
  }
}
