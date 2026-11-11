import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/live/live_chat_view.dart';
import 'package:paul_demo/profile/public_profile_view.dart';
import 'package:paul_demo/skills/skill_catalogue.dart';
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

class _SignaledChatRepository extends QuietChatRepository {
  _SignaledChatRepository(super.client);
  final signals = StreamController<String>.broadcast(sync: true);
  final opened = <String>[];
  @override
  Stream<String> watch() => signals.stream;
  @override
  Future<String> open(String peerId) async {
    opened.add(peerId);
    return 'new-conversation';
  }
}

void main() {
  setUpAll(() async {
    await SkillCatalogue.shared.suggest('marketing');
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  for (final (unavailableBeforeOpen, delayedRead, backgroundRead) in [
    (false, false, false),
    (true, false, false),
    (true, true, false),
    (true, true, true),
  ]) {
    testWidgets(
      'Global card access, unavailable=$unavailableBeforeOpen delayed=$delayedRead background=$backgroundRead',
      (tester) async {
        const actor = '10000000-0000-4000-8000-000000000001';
        const peer = '10000000-0000-4000-8000-000000000002';
        var connected = true;
        var available = true;
        var networkReads = 0;
        var profileReads = 0;
        Completer<void>? nextNetwork;
        Completer<void>? nextProfile;
        Map<String, dynamic> profile(String id, String name) => {
          'id': id,
          'profile_kind': id == peer ? 'managed' : 'member',
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
            final delayed = nextNetwork;
            nextNetwork = null;
            if (delayed != null) await delayed.future;
          } else if (request.url.path.endsWith('/account')) {
            final body = jsonDecode(request.body) as Map;
            if (body['action'] == 'capabilities') {
              return http.Response(
                jsonEncode({
                  'invited_registrations': 0,
                  'can_message_anyone': false,
                  'can_publish_community': false,
                  'offering_limit': 5,
                  'new_conversations_remaining': 1,
                  'quota_resets_at': '2026-11-12T00:00:00Z',
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            expect(body['action'], 'profile');
            expect(body['profile_id'], peer);
            profileReads++;
            final delayed = nextProfile;
            nextProfile = null;
            if (delayed != null) await delayed.future;
            if (!available) {
              return http.Response(
                jsonEncode({'code': 'profile_unavailable'}),
                404,
                headers: {'content-type': 'application/json'},
              );
            }
            data = {'profile': profile(peer, 'Search Peer QA')};
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
        final chat = _SignaledChatRepository(client);
        try {
          await client.auth.signInWithPassword(
            email: 'a@example.invalid',
            password: 'test-only',
          );
          await tester.pumpWidget(
            PaulLiveApp(
              client: client,
              appUrl: Uri.parse('https://test.invalid'),
              chatRepositoryFor: (_) => chat,
              draftPreferences: DraftPreferences(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('skill-search-field')),
            'mar',
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('suggest-marketing')));
          await tester.pumpAndSettle();
          final before = profileReads;
          final gate = delayedRead ? Completer<void>() : null;
          nextProfile = backgroundRead ? null : gate;
          nextNetwork = backgroundRead ? gate : null;
          if (backgroundRead) {
            chat.signals.add('refresh');
            await tester.pump();
            expect(networkReads, greaterThan(1));
          }
          connected = false;
          if (unavailableBeforeOpen) available = false;
          await tester.tap(find.byKey(const ValueKey('skill-result-$peer')));
          if (delayedRead) {
            await tester.pump();
            if (!backgroundRead) {
              expect(find.text('Opening profile…'), findsOneWidget);
            }
            expect(find.byType(PublicProfileView), findsNothing);
            gate!.complete();
          }
          await tester.pumpAndSettle();
          expect(profileReads, greaterThan(before));
          expect(
            find.byType(PublicProfileView),
            unavailableBeforeOpen ? findsNothing : findsOneWidget,
          );
          if (unavailableBeforeOpen) {
            expect(
              find.text(
                'Could not open this profile. It may no longer be available.',
              ),
              findsOneWidget,
            );
          } else {
            await tester.tap(find.byTooltip('Chat'));
            await tester.pumpAndSettle();
            expect(find.byType(LiveChatView), findsOneWidget);
            expect(chat.opened, [peer]);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(client.dispose);
          await chat.signals.close();
        }
      },
    );
  }
}
