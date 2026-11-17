import 'dart:convert';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:paul_demo/config/app_configuration.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/live/limited_preview_app.dart';
import 'package:paul_demo/live/public_guest_preview.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'public_preview_test.dart' show PublicFixture, person;
import 'support/onboarding_preferences.dart';

class JsonTest extends Fake implements YAJsonIsolate {
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
  test(
    'default launch is the primary app and never an implicit local demo',
    () {
      expect(AppConfiguration.environment().purpose, AppPurpose.app);
      expect(() => AppConfiguration.parsePurpose('typo'), throwsArgumentError);
    },
  );
  testWidgets(
    'main first launch shows source invitation and no public contacts',
    (tester) async {
      final requests = <String>[];
      final client = SupabaseClient(
        'https://unit.invalid',
        'public',
        isolate: JsonTest(),
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response('{}', 503);
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      await tester.pumpWidget(
        PaulLiveApp(
          client: client,
          appUrl: Uri.parse('https://paul.example'),
          purpose: AppPurpose.app,
          draftPreferences: DraftPreferences(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invite-code-input')), findsOneWidget);
      expect(find.byType(PublicGuestPreview), findsNothing);
      expect(find.byKey(const Key('tab-0')), findsNothing);
      expect(find.byKey(const Key('join-back')), findsNothing);
      expect(requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(client.dispose);
    },
  );
  testWidgets(
    'preview reads public data and stops before account editing or sign in',
    (tester) async {
      final requests = <String>[];
      final client = SupabaseClient(
        'https://unit.invalid',
        'public',
        isolate: JsonTest(),
        httpClient: MockClient((request) async {
          requests.add(request.url.path);
          return http.Response('{}', 503);
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final repository = PublicFixture();
      await tester.pumpWidget(
        LimitedPreviewApp(repository: repository, client: client),
      );
      await tester.pumpAndSettle();
      expect(find.text(person.profile.name), findsOneWidget);
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('guest-app-handoff')), findsOneWidget);
      expect(find.byKey(const Key('invite-code-input')), findsNothing);
      expect(find.byKey(const Key('name-field')), findsNothing);
      expect(requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
