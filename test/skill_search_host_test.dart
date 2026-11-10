import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/profile/public_profile_view.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'live_chat_api_test.dart' show token;
import 'support/onboarding_preferences.dart';
import 'support/quiet_chat_repository.dart';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  for (final disconnectBeforeOpen in [false, true]) {
    testWidgets(
      'Contacts search rechecks card access, disconnected=$disconnectBeforeOpen',
      (tester) async {
        const actor = '10000000-0000-4000-8000-000000000001';
        const peer = '10000000-0000-4000-8000-000000000002';
        var connected = true;
        var networkReads = 0;
        Map<String, dynamic> profile(String id, String name) => {
          'id': id,
          'name': name,
          'occupation': 'Designer',
          'summary': 'QA profile',
          'skills': ['Marketing'],
          'searching_skills': [],
          'contact_count': 1,
          'avatar_path': null,
        };
        final transport = MockClient((request) async {
          Object data;
          if (request.url.path.endsWith('/token')) {
            data = {
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
            };
          } else if (request.url.path.endsWith('/invitations')) {
            expect((jsonDecode(request.body) as Map)['action'], 'network');
            networkReads++;
            data = {
              'profile': profile(actor, 'Self QA'),
              'contacts': connected ? [profile(peer, 'Search Peer QA')] : [],
            };
          } else if (request.url.path.endsWith('/skill-search')) {
            final action = (jsonDecode(request.body) as Map)['action'];
            data = action == 'suggest'
                ? {
                    'suggestions': [
                      {'key': 'marketing', 'label': 'Marketing'},
                    ],
                  }
                : {
                    'query': 'marketing',
                    'kind': 'all',
                    'next_cursor': null,
                    'results': connected
                        ? [
                            {
                              'id': peer,
                              'name': 'Search Peer QA',
                              'occupation': 'Designer',
                              'matched_kinds': ['offering'],
                            },
                          ]
                        : [],
                  };
          } else {
            return http.Response('{}', 404);
          }
          return http.Response(
            jsonEncode(data),
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
          await tester.pumpWidget(
            PaulLiveApp(
              client: client,
              appUrl: Uri.parse('https://test.invalid'),
              chatRepositoryFor: (_) => QuietChatRepository(client),
              draftPreferences: DraftPreferences(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('skill-search-field')),
            'mar',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('suggest-marketing')));
          await tester.pumpAndSettle();
          final before = networkReads;
          if (disconnectBeforeOpen) connected = false;
          await tester.tap(find.byKey(const ValueKey('skill-result-$peer')));
          await tester.pumpAndSettle();
          expect(networkReads, greaterThan(before));
          expect(
            find.byType(PublicProfileView),
            disconnectBeforeOpen ? findsNothing : findsOneWidget,
          );
          if (disconnectBeforeOpen) {
            expect(
              find.text(
                'This profile is no longer available in your contacts.',
              ),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('skill-result-$peer')),
              findsNothing,
            );
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(client.dispose);
        }
      },
    );
  }
}
