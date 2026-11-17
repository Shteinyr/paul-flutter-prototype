import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/public_guest_preview.dart';
import 'package:paul_demo/live/public_preview_api.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/skills/skill_catalogue.dart';

const person = PublicProfile(
  id: '10000000-0000-4000-8000-000000000001',
  profile: UserProfile(
    name: 'Real community member',
    occupation: 'Designer',
    summary: 'Actual public biography',
    skills: ['Design'],
  ),
);
Map<String, dynamic> wireProfile() => {
  'id': person.id,
  'name': person.profile.name,
  'occupation': person.profile.occupation,
  'summary': person.profile.summary,
  'skills': ['Design'],
  'searching_skills': <String>[],
  'contact_count': 2,
  'avatar_url': null,
};

class PublicFixture implements PublicPreviewRepository {
  bool fail = false;
  final calls = <String>[];
  @override
  PublicProfile? cachedProfile(String id) => id == person.id ? person : null;
  @override
  Future<PublicProfilePage> profiles({
    String query = '',
    SkillSearchKind kind = SkillSearchKind.all,
    Map<String, dynamic>? cursor,
    bool namesOnly = false,
  }) async {
    calls.add(namesOnly ? 'names' : 'profiles');
    if (fail) throw StateError('unavailable');
    return PublicProfilePage([person], query, null);
  }

  @override
  Future<PublicProfile?> profile(String id) async {
    calls.add('profile');
    return cachedProfile(id);
  }

  CommunityRequest get hiring => CommunityRequest(
    id: '20000000-0000-4000-8000-000000000001',
    author: ChatPeer(
      id: person.id,
      name: person.profile.name,
      occupation: person.profile.occupation,
    ),
    skill: 'Actual hiring skill',
    message: 'An actual public request',
    createdAt: DateTime.now().toUtc(),
    expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    isAuthor: false,
  );
  @override
  Future<CommunityPage> feed({Map<String, dynamic>? cursor}) async {
    calls.add('feed');
    return CommunityPage([hiring], null, DateTime.now().toUtc());
  }

  @override
  Future<CommunityRequest?> request(String id) async {
    calls.add('get');
    return hiring;
  }
}

class _EntryHarness extends StatefulWidget {
  const _EntryHarness(this.repository);
  final PublicPreviewRepository repository;
  @override
  State<_EntryHarness> createState() => _EntryHarnessState();
}

class _EntryHarnessState extends State<_EntryHarness> {
  final browsing = PublicGuestBrowsingState();
  bool joining = false;
  @override
  Widget build(BuildContext context) => joining
      ? Scaffold(
          body: Column(
            children: [
              const Text('Join'),
              TextButton(
                onPressed: () => setState(() => joining = false),
                child: const Text('Back'),
              ),
            ],
          ),
        )
      : PublicGuestPreview(
          repository: widget.repository,
          browsingState: browsing,
          onEditProfile: () {},
          onRequireSignIn: () {
            Navigator.of(context).popUntil((route) => route.isFirst);
            setState(() => joining = true);
          },
        );
}

void main() {
  setUpAll(() async {
    final font = FontLoader('NotoSans')
      ..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'));
    await font.load();
  });
  test(
    'concurrent public card reads share a request but later renewal stays fresh',
    () async {
      final pending = Completer<http.Response>();
      var requests = 0;
      final client = MockClient((request) {
        requests++;
        expect((jsonDecode(request.body) as Map)['profile_id'], person.id);
        if (requests == 1) return pending.future;
        return Future.value(
          http.Response(jsonEncode({'profile': wireProfile()}), 200),
        );
      });
      final api = PublicPreviewApi(
        url: Uri.parse('https://public.invalid'),
        publishableKey: 'public-key',
        transport: client,
      );
      final first = api.profile(person.id);
      final second = api.profile(person.id);
      expect(identical(first, second), isTrue);
      pending.complete(
        http.Response(jsonEncode({'profile': wireProfile()}), 200),
      );
      expect((await first)!.id, person.id);
      expect((await second)!.id, person.id);
      expect(requests, 1);
      await api.profile(person.id);
      expect(requests, 2);
      client.close();
    },
  );
  test(
    'public transport avoids preflight headers and never sends a user token or private function',
    () async {
      final actions = <String>[];
      final client = MockClient((r) async {
        expect(r.url.path, '/functions/v1/public-preview');
        expect(r.headers['authorization'], isNull);
        expect(r.headers['apikey'], isNull);
        expect(r.headers['content-type'], startsWith('text/plain'));
        final b = jsonDecode(r.body) as Map;
        actions.add(b['action'] as String);
        return http.Response(
          jsonEncode(
            b['action'] == 'profile'
                ? {'profile': wireProfile()}
                : {
                    'query': 'real',
                    'profiles': [wireProfile()],
                    'next_cursor': null,
                  },
          ),
          200,
        );
      });
      final api = PublicPreviewApi(
        url: Uri.parse('https://public.invalid'),
        publishableKey: 'public-key',
        transport: client,
      );
      expect(
        (await api.profiles()).profiles.single.profile.name,
        person.profile.name,
      );
      expect(
        (await api.profile(person.id))!.profile.summary,
        person.profile.summary,
      );
      await PublicSearchRepository(api).searchNames('real');
      expect(actions, ['profiles', 'profile', 'names']);
      client.close();
    },
  );
  test(
    'public community repository cannot create or close a request',
    () async {
      final fixture = PublicFixture();
      final repo = PublicCommunityRepository(fixture);
      await expectLater(
        repo.create('id', 'Design', 'text'),
        throwsA(isA<CommunityException>()),
      );
      await expectLater(
        repo.close('id', 'request'),
        throwsA(isA<CommunityException>()),
      );
      expect(fixture.calls, isEmpty);
    },
  );
  testWidgets(
    'guest name search opens real public cards without exposing mutual contacts',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = PublicFixture();
      var signIns = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSans'),
          home: PublicGuestPreview(
            repository: repo,
            onRequireSignIn: () => signIns++,
            onEditProfile: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => SkillCatalogue.shared.suggest('Real'));
      await tester.enterText(
        find.byKey(const Key('skill-search-field')),
        'Real',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const Key('search-people-by-name')));
      await tester.pumpAndSettle();
      expect(repo.calls, contains('names'));
      expect(signIns, 0);
      expect(find.text('All'), findsNothing);
      expect(find.textContaining('Mutual contacts'), findsNothing);
      await tester.tap(find.text(person.profile.name));
      await tester.pumpAndSettle();
      expect(find.text(person.profile.summary), findsOneWidget);
      expect(signIns, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Join cancellation restores the actual public profile and Hiring detail that requested entry',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSans'),
          home: _EntryHarness(PublicFixture()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(person.profile.name));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-profile-chat')));
      await tester.pumpAndSettle();
      expect(find.text('Join'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text(person.profile.summary), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tab-1')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.textContaining('Actual hiring skill', findRichText: true),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message author'));
      await tester.pumpAndSettle();
      expect(find.text('Join'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('An actual public request'), findsOneWidget);
      expect(find.text('Close request'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'guest browses actual profiles and Hiring while messaging requires sign in',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = PublicFixture();
      var signIns = 0;
      var edits = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSans'),
          home: PublicGuestPreview(
            repository: repo,
            onRequireSignIn: () => signIns++,
            onEditProfile: () => edits++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(person.profile.name), findsOneWidget);
      expect(find.text('Julia Robinson'), findsNothing);
      await tester.tap(find.text(person.profile.name));
      await tester.pumpAndSettle();
      expect(find.text(person.profile.summary), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-profile-chat')));
      await tester.pumpAndSettle();
      expect(signIns, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tab-1')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Actual hiring skill', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Sales Representative'), findsNothing);
      expect(find.text('Close request'), findsNothing);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      expect(find.text('Sign up to chat'), findsOneWidget);
      expect(signIns, 1); // A tab inspection itself does not force Join.
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      expect(edits, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'failed public loading shows Retry and never substitutes demonstration people',
    (tester) async {
      final repo = PublicFixture()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSans'),
          home: PublicGuestPreview(
            repository: repo,
            onRequireSignIn: () {},
            onEditProfile: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load profiles. Please retry.'),
        findsOneWidget,
      );
      expect(find.text('Paul Galda'), findsNothing);
      repo.fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(person.profile.name), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
