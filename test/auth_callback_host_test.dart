import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/auth_callback.dart';
import 'package:paul_demo/live/browser_storage.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/onboarding/onboarding_draft_store.dart';
import 'package:paul_demo/onboarding/onboarding_flow.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'live_chat_api_test.dart' show token;
import 'support/onboarding_preferences.dart';
import 'support/quiet_chat_repository.dart';

const _user = '10000000-0000-4000-8000-000000000001';
const _inviteKey = 'paul.live.pending.invitation.v1';
const _draftKey = 'paul.live.pending.profile.v1';
const _guardKey = 'paul.live.pending.auth-failure.v1';

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
  void clear() {
    for (final key in [
      _inviteKey,
      _draftKey,
      _guardKey,
      'paul.live.pending.finalize.v1',
      'paul.live.entry.return.v1',
    ]) {
      removeSessionValue(key);
    }
  }

  setUp(clear);
  tearDown(clear);

  for (final member in [false, true]) {
    testWidgets(
      'failed callback remains safe through reload and Back, member=$member',
      (tester) async {
        final requests = <String>[];
        final preferences = DraftPreferences();
        final png = (await rootBundle.load(
          'assets/people/paul-galda.png',
        )).buffer.asUint8List();
        final draft = UserProfile(
          name: 'Saved local draft',
          occupation: '',
          summary: 'Saved summary',
          skills: const ['Flutter'],
          photo: png,
        );
        final store = OnboardingDraftStore(preferences: preferences)..step = 2;
        await store.write(draft);
        writeSessionValue(_draftKey, draft.encode());
        writeSessionValue(_inviteKey, 'a' * 64);
        writeSessionValue('paul.live.pending.finalize.v1', '1');
        final client = SupabaseClient(
          'https://local.invalid',
          'local-key',
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async {
            final body = jsonDecode(request.body) as Map;
            final action = body['action'] as String? ?? 'unknown';
            requests.add(action);
            final Object response = switch (action) {
              'network' => {
                'profile': member
                    ? {
                        'id': _user,
                        'name': 'Existing member',
                        'occupation': '',
                        'summary': 'Existing profile',
                        'skills': ['Flutter'],
                        'searching_skills': <String>[],
                        'avatar_path': null,
                        'contact_count': 0,
                      }
                    : null,
                'contacts': [],
              },
              'capabilities' => {
                'invited_registrations': 0,
                'can_message_anyone': false,
                'can_publish_community': false,
                'offering_limit': 5,
                'new_conversations_remaining': 1,
                'quota_resets_at': '2030-01-01T00:00:00Z',
              },
              _ => <String, dynamic>{},
            };
            return http.Response(
              jsonEncode(response),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        try {
          if (member) {
            await client.auth.setInitialSession(
              jsonEncode({
                'access_token': token(_user),
                'refresh_token': 'local-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': _user,
                  'aud': 'authenticated',
                  'created_at': '2026-01-01T00:00:00Z',
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
            );
          }
          final initialSession = client.auth.currentSession;
          Widget app({bool failed = false}) => PaulLiveApp(
            client: client,
            appUrl: Uri.parse('https://app.invalid'),
            authCallback: failed,
            authCallbackFailed: failed,
            draftPreferences: preferences,
            chatRepositoryFor: (_) => QuietChatRepository(client),
          );
          await tester.pumpWidget(app(failed: true));
          await tester.pumpAndSettle();
          expect(find.text(authCallbackFailureMessage), findsOneWidget);
          expect(requests, isNot(contains('redeem')));
          expect(readSessionValue(_inviteKey), 'a' * 64);
          expect(readSessionValue(_draftKey), draft.encode());
          expect(readSessionValue('paul.live.pending.finalize.v1'), isNull);
          expect(readSessionValue(_guardKey), '1');
          if (member) {
            expect(find.text('Existing member'), findsOneWidget);
            await tester.tap(find.text('Continue to Contacts'));
            await tester.pumpAndSettle();
            expect(find.text(authCallbackFailureMessage), findsNothing);
            expect(readSessionValue(_guardKey), '1');
          } else {
            expect(requests, isEmpty);
          }
          // A fresh host represents reloading the cleaned callback address.
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.pumpWidget(app());
          await tester.pumpAndSettle();
          expect(find.text(authCallbackFailureMessage), findsNothing);
          expect(requests, isNot(contains('redeem')));
          expect(readSessionValue(_inviteKey), 'a' * 64);
          expect(readSessionValue(_guardKey), '1');
          expect(identical(client.auth.currentSession, initialSession), isTrue);
          final saved = await store.read();
          expect(saved.name, draft.name);
          expect(saved.photo, png);
          if (!member) {
            expect(requests, isEmpty);
            await tester.tap(find.byKey(const Key('join-back')));
            await tester.pumpAndSettle();
            expect(find.byType(OnboardingFlow), findsOneWidget);
            expect((await store.read()).photo, png);
            expect(readSessionValue(_inviteKey), 'a' * 64);
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
