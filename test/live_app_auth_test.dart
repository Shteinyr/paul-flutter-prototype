import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/browser_storage.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/live/live_api.dart';
import 'package:paul_demo/onboarding/onboarding_draft_store.dart';
import 'package:paul_demo/onboarding/onboarding_flow.dart';
import 'package:paul_demo/profile/public_profile_view.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'support/onboarding_preferences.dart';
import 'support/quiet_chat_repository.dart';

const _a = '00000000-0000-4000-8000-000000000001';
const _b = '00000000-0000-4000-8000-000000000002';
const _c = '00000000-0000-4000-8000-000000000003';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

Map<String, dynamic> _profile(String id, String name, {String? avatar}) => {
  'id': id,
  'name': name,
  'occupation': '',
  'summary': 'Test profile',
  'skills': ['Flutter'],
  'searching_skills': <String>[],
  'contact_count': id == _c ? 0 : 1,
  'avatar_path': avatar,
};

String _jwt(String id) {
  final claims = {
    'sub': id,
    'aud': 'authenticated',
    'role': 'authenticated',
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
        1000,
  };
  return 'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature';
}

class _IdentityChatRepository extends QuietChatRepository {
  _IdentityChatRepository(super.client);
  String? openedBy;
  @override
  Future<String> open(String peerId) async {
    openedBy = currentUserId;
    return 'latest-identity-conversation';
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  setUp(() {
    removeSessionValue('paul.live.pending.invitation.v1');
    removeSessionValue('paul.live.pending.profile.v1');
    removeSessionValue('paul.live.pending.finalize.v1');
  });

  for (final transportFailure in [false, true]) {
    testWidgets(
      'member startup exposes retry after network failure, transport=$transportFailure',
      (tester) async {
        var failing = true;
        var signIns = 0;
        final transport = MockClient((request) async {
          Object data;
          if (request.url.path.endsWith('/token')) {
            signIns++;
            data = {
              'access_token': _jwt(_a),
              'refresh_token': 'original-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': _a,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            };
          } else if (request.url.path.endsWith('/invitations')) {
            if (failing) {
              if (transportFailure) {
                throw http.ClientException('Connection reset');
              }
              return http.Response(
                jsonEncode({'code': 'server_unavailable'}),
                503,
                headers: {'content-type': 'application/json'},
              );
            }
            data = {
              'profile': _profile(_a, 'Recovered member'),
              'contacts': [],
            };
          } else {
            return http.Response(
              '{}',
              503,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://test.supabase.co',
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
          final original = client.auth.currentSession;
          await tester.pumpWidget(
            PaulLiveApp(
              client: client,
              appUrl: Uri.parse('https://test.invalid'),
              draftPreferences: DraftPreferences(),
              chatRepositoryFor: (_) => QuietChatRepository(client),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('member-startup-error')), findsOneWidget);
          expect(find.text('Preview · Demonstration profiles'), findsNothing);
          expect(client.auth.currentSession, same(original));
          failing = false;
          await tester.tap(find.byKey(const Key('member-startup-retry')));
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('skill-search-field')), findsOneWidget);
          expect(client.auth.currentUser?.id, _a);
          expect(client.auth.currentSession, same(original));
          expect(signIns, 1);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(client.dispose);
        }
      },
    );
  }

  testWidgets(
    'registration upload cannot redeem an invitation after account switch',
    (tester) async {
      final upload = Completer<http.Response>();
      var redemptions = 0;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          final id =
              (jsonDecode(request.body) as Map)['email'] == 'a@example.invalid'
              ? _a
              : _c;
          return http.Response(
            jsonEncode({
              'access_token': _jwt(id),
              'refresh_token': 'test-refresh',
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
        if (request.url.path.startsWith('/storage/')) return upload.future;
        redemptions++;
        return http.Response(
          '{}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-key',
        httpClient: transport,
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.signInWithPassword(
        email: 'a@example.invalid',
        password: 'test-only',
      );
      final pending = LiveApi(client).redeem(
        List.filled(64, 'a').join(),
        draft: UserProfile(
          name: 'Test member',
          summary: 'Test summary',
          skills: const ['Flutter'],
          photo: base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=',
          ),
        ),
      );
      await tester.pump();
      await client.auth.signInWithPassword(
        email: 'c@example.invalid',
        password: 'test-only',
      );
      final rejected = expectLater(
        pending,
        throwsA(
          isA<LiveApiException>().having(
            (error) => error.code,
            'code',
            'sign_in_required',
          ),
        ),
      );
      upload.complete(http.Response('{"Key":"avatars/test.png"}', 200));
      await rejected;
      expect(redemptions, 0);
      await tester.runAsync(client.dispose);
    },
  );

  for (final changeAccount in [false, true]) {
    testWidgets(
      changeAccount
          ? 'delayed avatar cannot open the previous account profile after account switch'
          : 'delayed avatar cannot open a protected profile after UI logout',
      (tester) async {
        tester.view.physicalSize = const Size(402, 874);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final photo = Completer<http.Response>();
        late SupabaseClient client;
        var downloads = 0;
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            final email = (jsonDecode(request.body) as Map)['email'];
            final id = email == 'a@example.invalid' ? _a : _c;
            return http.Response(
              jsonEncode({
                'access_token': _jwt(id),
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': id,
                  'aud': 'authenticated',
                  'role': 'authenticated',
                  'email': email,
                  'created_at': DateTime.utc(2026).toIso8601String(),
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/logout')) {
            return http.Response('{}', 200);
          }
          if (request.url.path.startsWith('/storage/')) {
            downloads++;
            return photo.future;
          }
          if (request.url.path.endsWith('/invitations')) {
            final id = client.auth.currentUser!.id;
            return http.Response(
              jsonEncode({
                'profile': _profile(id, id == _a ? 'Member A' : 'Member C'),
                'contacts': id == _a
                    ? [_profile(_b, 'Contact B', avatar: '$_b/avatar.png')]
                    : [],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('{}', 404);
        });
        client = SupabaseClient(
          'https://test.supabase.co',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        await client.auth.signInWithPassword(
          email: 'a@example.invalid',
          password: 'test-only',
        );
        await tester.pumpWidget(
          PaulLiveApp(
            client: client,
            chatRepositoryFor: (_) => QuietChatRepository(client),
            appUrl: Uri.parse('https://test.example'),
            googleEnabled: false,
            appleEnabled: false,
            draftPreferences: DraftPreferences(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Contact B'), findsOneWidget);
        expect(find.byKey(const Key('tab-0')), findsOneWidget);
        expect(find.byKey(const Key('tab-3')), findsOneWidget);
        await tester.tap(find.text('Contact B'));
        await tester.pump();
        expect(downloads, greaterThanOrEqualTo(2));
        if (changeAccount) {
          await client.auth.signInWithPassword(
            email: 'c@example.invalid',
            password: 'test-only',
          );
        } else {
          await tester.tap(find.byKey(const Key('tab-3')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Sign out'));
          await tester.tap(find.text('Sign out'));
        }
        await tester.pump();
        if (!changeAccount) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
        }
        await tester.pumpAndSettle();
        photo.complete(
          http.Response.bytes(
            base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=',
            ),
            200,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PublicProfileView), findsNothing);
        expect(find.text('Contact B'), findsNothing);
        expect(
          find.text(
            changeAccount ? 'Member C' : 'Preview · Demonstration profiles',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
      },
    );
  }

  for (final (pendingFinalization, networkFailure, authCallback) in [
    (true, false, true),
    (false, false, false),
    (true, true, true),
    (true, false, false),
    (false, false, true),
  ]) {
    final shouldFinalize = pendingFinalization && authCallback;
    testWidgets(
      networkFailure
          ? 'successful membership survives follow-up network failure and retries without OAuth'
          : pendingFinalization && !authCallback
          ? 'ordinary reload clears a stale finalization marker without activating membership'
          : authCallback && !pendingFinalization
          ? 'an unconfirmed OAuth callback cannot create membership'
          : shouldFinalize
          ? 'OAuth return finalizes the latest local draft instead of the submitted snapshot'
          : 'cancelled submit cannot auto-finalize after ordinary member sign-in',
      (tester) async {
        tester.view.physicalSize = const Size(402, 874);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final preferences = DraftPreferences();
        final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=',
        );
        final original = UserProfile(
          name: 'Old submitted name',
          summary: 'Original summary',
          photo: png,
          skills: const ['Flutter'],
        );
        final latest = original.copyWith(
          name: 'Latest edited name',
          summary: 'Latest edited summary',
        );
        final store = OnboardingDraftStore(preferences: preferences)..step = 2;
        await store.write(latest);
        writeSessionValue('paul.live.pending.profile.v1', original.encode());
        writeSessionValue(
          'paul.live.pending.invitation.v1',
          List.filled(64, 'a').join(),
        );
        if (pendingFinalization) {
          writeSessionValue('paul.live.pending.finalize.v1', '1');
        }
        Map<String, dynamic>? submitted;
        var failNetwork = networkFailure;
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/token')) {
            return http.Response(
              jsonEncode({
                'access_token': _jwt(_a),
                'refresh_token': 'test-refresh',
                'token_type': 'bearer',
                'expires_in': 3600,
                'user': {
                  'id': _a,
                  'aud': 'authenticated',
                  'email': 'qa@example.invalid',
                  'created_at': DateTime.utc(2026).toIso8601String(),
                  'app_metadata': {},
                  'user_metadata': {},
                },
              }),
              200,
            );
          }
          if (request.url.path.startsWith('/storage/')) {
            if (request.method == 'GET') return http.Response.bytes(png, 200);
            return http.Response(
              jsonEncode({
                'Key': 'avatars/${request.url.path.split('/avatars/').last}',
              }),
              200,
            );
          }
          final body = jsonDecode(request.body) as Map;
          if (body['action'] == 'redeem') {
            submitted = Map<String, dynamic>.from(body['profile'] as Map);
          }
          if (body['action'] == 'network') {
            if (submitted != null && failNetwork) {
              return http.Response(
                '{"code":"server_unavailable"}',
                503,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              jsonEncode({
                'profile': submitted == null
                    ? null
                    : {...submitted!, 'id': _a, 'contact_count': 0},
                'contacts': [],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://test.supabase.co',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        await client.auth.signInWithPassword(
          email: 'qa@example.invalid',
          password: 'test-only',
        );
        await tester.pumpWidget(
          PaulLiveApp(
            client: client,
            chatRepositoryFor: (_) => QuietChatRepository(client),
            appUrl: Uri.parse('https://test.example'),
            googleEnabled: false,
            appleEnabled: false,
            draftPreferences: preferences,
            authCallback: authCallback,
          ),
        );
        await tester.pump();
        if (!shouldFinalize) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 200)),
          );
        }
        await tester.pumpAndSettle();
        if (networkFailure) {
          expect(find.text('Retry'), findsOneWidget);
          expect(submitted?['name'], latest.name);
          failNetwork = false;
          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
        }
        if (shouldFinalize) {
          expect(submitted?['name'], latest.name);
          expect(submitted?['summary'], latest.summary);
          expect(find.byType(OnboardingFlow), findsNothing);
          expect((await store.read()).hasData, false);
        } else {
          expect(submitted, null);
          expect(find.byType(OnboardingFlow), findsNothing);
          expect(find.text('Preview · Demonstration profiles'), findsOneWidget);
          expect((await store.read()).name, latest.name);
        }
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(client.dispose);
      },
    );
  }

  testWidgets(
    'a delayed previous identity cleanup cannot replace the latest account',
    (tester) async {
      final preferences = DraftPreferences();
      late SupabaseClient client;
      late _IdentityChatRepository latestChat;
      final transport = MockClient((request) async {
        if (request.url.path.endsWith('/token')) {
          final email = (jsonDecode(request.body) as Map)['email'];
          final id = email == 'a@example.invalid'
              ? _a
              : email == 'b@example.invalid'
              ? _b
              : _c;
          return http.Response(
            jsonEncode({
              'access_token': _jwt(id),
              'refresh_token': 'synthetic-refresh',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': id,
                'aud': 'authenticated',
                'email': email,
                'created_at': DateTime.utc(2026).toIso8601String(),
                'app_metadata': {},
                'user_metadata': {},
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'profile': _profile(
              client.auth.currentUser!.id,
              client.auth.currentUser!.id == _c
                  ? 'Latest member C'
                  : 'Earlier member',
            ),
            'contacts': client.auth.currentUser!.id == _c
                ? [_profile(_b, 'Latest account contact')]
                : [],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      client = SupabaseClient(
        'https://test.supabase.co',
        'test-key',
        httpClient: transport,
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await client.auth.signInWithPassword(
        email: 'a@example.invalid',
        password: 'synthetic',
      );
      await tester.pumpWidget(
        PaulLiveApp(
          client: client,
          appUrl: Uri.parse('https://paul.example'),
          draftPreferences: preferences,
          chatRepositoryFor: (_) =>
              latestChat = _IdentityChatRepository(client),
        ),
      );
      await tester.pumpAndSettle();
      final previousCleanup = Completer<void>(),
          latestCleanup = Completer<void>();
      preferences.writeGate = previousCleanup;
      await client.auth.signInWithPassword(
        email: 'b@example.invalid',
        password: 'synthetic',
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Earlier member'), findsNothing);
      preferences.writeGate = latestCleanup;
      await client.auth.signInWithPassword(
        email: 'c@example.invalid',
        password: 'synthetic',
      );
      await tester.pump();
      latestCleanup.complete();
      await tester.pumpAndSettle();
      expect(find.text('Latest member C'), findsOneWidget);
      previousCleanup.complete();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Latest member C'));
      await tester.pumpAndSettle();
      expect(find.byType(PublicProfileView), findsOneWidget);
      expect(find.text('Latest member C'), findsOneWidget);
      expect(find.byKey(const Key('edit-public-profile')), findsOneWidget);
      expect(find.byKey(const Key('open-profile-chat')), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Latest account contact'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-profile-chat')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-chat-message-field')), findsOneWidget);
      expect(latestChat.openedBy, _c);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
    },
  );
}
