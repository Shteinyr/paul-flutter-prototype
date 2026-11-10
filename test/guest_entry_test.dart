import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/browser_storage.dart';
import 'package:paul_demo/live/guest_preview.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/onboarding/onboarding_draft_store.dart';
import 'package:paul_demo/onboarding/onboarding_flow.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'support/onboarding_preferences.dart';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

Future<void> _previewReady(WidgetTester tester) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.text('Paul Galda').evaluate().isNotEmpty) return;
  }
  expect(find.text('Paul Galda'), findsOneWidget);
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

  testWidgets(
    'first visit browses sample profiles and skills with no server or draft writes',
    (tester) async {
      final requests = <String>[];
      final preferences = DraftPreferences();
      var settingsLoads = 0;
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-key',
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response('{}', 503);
        }),
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await tester.pumpWidget(
        PaulLiveApp(
          client: client,
          appUrl: Uri.parse('https://paul.example'),
          draftPreferences: preferences,
          loadAuthProviders: () async {
            settingsLoads++;
            throw StateError('offline');
          },
        ),
      );
      await _previewReady(tester);
      expect(find.text('Join'), findsNothing);
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pumpAndSettle();
      expect(find.byType(GuestPreview), findsOneWidget);
      expect(find.text('Join'), findsNothing);
      expect(
        tester.widget<InkWell>(find.byKey(const Key('tab-1'))).onTap,
        isNull,
      );
      expect(requests, isEmpty);
      expect(find.text('Julia Robinson'), findsOneWidget);
      await tester.tap(find.text('Julia Robinson'));
      await tester.pumpAndSettle();
      expect(find.text('Public Profile'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('see-more-offered')));
      await tester.tap(find.byKey(const Key('see-more-offered')));
      await tester.pumpAndSettle();
      expect(find.text('Design Handoff'), findsOneWidget);
      expect(requests, isEmpty);
      expect(settingsLoads, 0);
      expect(preferences.values, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-profile-chat')));
      await tester.pumpAndSettle();
      expect(find.text('Join'), findsNWidgets(2));
      expect(find.text('Already a member? Sign in'), findsOneWidget);
      expect(requests, isEmpty);
      await tester.tap(find.text('Already a member? Sign in'));
      await tester.pumpAndSettle();
      expect(settingsLoads, 1);
      expect(
        find.text('Could not open sign-in. Please try again.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Back to preview'));
      await _previewReady(tester);
      expect(find.text('Paul Galda'), findsOneWidget);
      expect(preferences.values, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
    },
  );

  testWidgets(
    'incoming invitation waits for deliberate Join and preserves draft across guest return and reload',
    (tester) async {
      final actions = <String>[];
      final preferences = DraftPreferences();
      final draft = OnboardingDraftStore(preferences: preferences);
      await draft.write(const UserProfile(skills: ['Flutter']));
      writeSessionValue(
        'paul.live.pending.invitation.v1',
        'synthetic-pending-token',
      );
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-key',
        httpClient: MockClient((request) async {
          actions.add((jsonDecode(request.body) as Map)['action'] as String);
          return http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      Widget app() => PaulLiveApp(
        client: client,
        appUrl: Uri.parse('https://paul.example'),
        draftPreferences: preferences,
      );
      await tester.pumpWidget(app());
      await _previewReady(tester);
      expect(find.byType(GuestPreview), findsOneWidget);
      expect(actions, isEmpty);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      expect(find.text('Continue with this invitation.'), findsOneWidget);
      expect(find.byKey(const Key('invite-code-input')), findsNothing);
      expect(actions, isEmpty);
      await tester.tap(find.text('Join').last);
      await tester.pumpAndSettle();
      expect(actions, ['check']);
      expect(find.byType(OnboardingFlow), findsOneWidget);
      expect(find.text('Flutter'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await _previewReady(tester);
      expect(find.byType(GuestPreview), findsOneWidget);
      expect((await draft.read()).skills, ['Flutter']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await _previewReady(tester);
      expect(find.byType(GuestPreview), findsOneWidget);
      expect(actions, ['check']);
      expect(
        readSessionValue('paul.live.pending.invitation.v1'),
        'synthetic-pending-token',
      );
      expect((await draft.read()).skills, ['Flutter']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
    },
  );

  testWidgets(
    'cancelled entry ignores delayed invitation and provider responses',
    (tester) async {
      final check = Completer<http.Response>();
      final providers = Completer<({bool google, bool apple})>();
      final client = SupabaseClient(
        'https://test.supabase.co',
        'test-key',
        httpClient: MockClient((request) => check.future),
        isolate: _Json(),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await tester.pumpWidget(
        PaulLiveApp(
          client: client,
          appUrl: Uri.parse('https://paul.example'),
          draftPreferences: DraftPreferences(),
          loadAuthProviders: () => providers.future,
        ),
      );
      await _previewReady(tester);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('invite-code-input')),
        '12345678',
      );
      await tester.tap(find.text('Join').last);
      await tester.pump();
      await tester.tap(find.text('Back to preview'));
      await _previewReady(tester);
      check.complete(
        http.Response('{}', 200, headers: {'content-type': 'application/json'}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(GuestPreview), findsOneWidget);
      expect(find.byType(OnboardingFlow), findsNothing);
      expect(readSessionValue('paul.live.pending.invitation.v1'), isNull);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Already a member? Sign in'));
      await tester.pump();
      await tester.tap(find.text('Back to preview'));
      await _previewReady(tester);
      providers.complete((google: true, apple: false));
      await tester.pumpAndSettle();
      expect(find.byType(GuestPreview), findsOneWidget);
      expect(find.text('Continue with Google'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
    },
  );

  testWidgets(
    'initialization failure keeps preview and exposes retry only after protected intent',
    (tester) async {
      var retries = 0;
      await tester.pumpWidget(GuestUnavailableApp(onRetry: () => retries++));
      await _previewReady(tester);
      expect(find.text('Connection unavailable'), findsNothing);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      expect(find.text('Connection unavailable'), findsOneWidget);
      await tester.tap(find.text('Back to preview'));
      await tester.pumpAndSettle();
      expect(find.text('Julia Robinson'), findsOneWidget);
      expect(retries, 0);
      await tester.tap(find.byTooltip('My QR code'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(retries, 1);
    },
  );
}
