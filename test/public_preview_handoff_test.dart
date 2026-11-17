import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/live/guest_invitation_prompt.dart';
import 'package:paul_demo/live/limited_preview_app.dart';
import 'package:paul_demo/live/invitation_entry_view.dart';
import 'package:paul_demo/live/public_preview_api.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/skills/skill_catalogue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'public_preview_test.dart' show PublicFixture, person;

class _ManyPeople extends PublicFixture {
  final people = List.generate(
    20,
    (i) => PublicProfile(
      id: '10000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
      profile: UserProfile(
        name: i == 0 ? person.profile.name : 'Community member $i',
        occupation: 'Designer',
        summary: 'Public biography $i',
        skills: const ['Design'],
        searchingSkills: const ['Design'],
      ),
    ),
  );
  @override
  PublicProfile? cachedProfile(String id) =>
      people.where((p) => p.id == id).firstOrNull;
  @override
  Future<PublicProfilePage> profiles({
    String query = '',
    SkillSearchKind kind = SkillSearchKind.all,
    Map<String, dynamic>? cursor,
    bool namesOnly = false,
  }) async {
    calls.add('profiles');
    return PublicProfilePage(people, query, null);
  }
}

class _DatedRequests extends PublicFixture {
  List<CommunityRequest> get requests => [
    for (final days in [0, 3, 10])
      CommunityRequest(
        id: '20000000-0000-4000-8000-${days.toString().padLeft(12, '0')}',
        author: hiring.author,
        skill: 'Actual skill $days',
        message: 'Public request $days',
        createdAt: DateTime.now().toUtc().subtract(Duration(days: days)),
        expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
        isAuthor: false,
      ),
  ];
  @override
  Future<CommunityPage> feed({Map<String, dynamic>? cursor}) async {
    calls.add('feed');
    return CommunityPage(
      requests,
      cursor == null ? {'next': 'page'} : null,
      DateTime.now().toUtc(),
    );
  }

  @override
  Future<CommunityRequest?> request(String id) async =>
      requests.where((r) => r.id == id).firstOrNull;
}

Future<void> _show(
  WidgetTester tester,
  PublicPreviewRepository repository,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = SupabaseClient(
    'https://public.invalid',
    'public-key',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient((request) async {
      fail(
        'Public browsing must not call Auth/private APIs: ${request.url.path}',
      );
    }),
  );
  await tester.pumpWidget(
    LimitedPreviewApp(repository: repository, client: client),
  );
  await tester.pumpAndSettle();
}

Future<void> _dismiss(WidgetTester tester) async {
  await tester.tapAt(const Offset(8, 400));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
    await SkillCatalogue.shared.suggest('Design');
  });

  testWidgets('guest Profile opens P16 handoff without browser registration', (
    tester,
  ) async {
    final repository = PublicFixture();
    await _show(tester, repository);
    await tester.tap(find.byKey(const Key('tab-3')));
    await tester.pumpAndSettle();
    expect(find.byType(GuestAppPrompt), findsOneWidget);
    expect(find.text('You’re Invited!'), findsOneWidget);
    expect(find.text('Get app'), findsOneWidget);
    expect(find.byType(InvitationEntryView), findsNothing);
    expect(find.byKey(const Key('invite-code-input')), findsNothing);
    expect(find.text('Join'), findsNothing);
    expect(find.text('About You'), findsNothing);
    expect(find.byKey(const Key('guest-invitation-code')), findsNothing);
    expect(find.text('Copy, paste code in App to connect'), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('guest-get-app')))
          .onPressed,
      isNull,
    );
    await _dismiss(tester);
    expect(find.text(person.profile.name), findsOneWidget);
    expect(repository.calls, ['profiles']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling Chat handoff retains public profile and its origin', (
    tester,
  ) async {
    final repository = PublicFixture();
    await _show(tester, repository);
    await tester.tap(find.text(person.profile.name));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-profile-chat')));
    await tester.pumpAndSettle();
    expect(find.byType(GuestAppPrompt), findsOneWidget);
    await _dismiss(tester);
    expect(find.text(person.profile.summary), findsOneWidget);
    expect(repository.calls, ['profiles', 'profile']);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text(person.profile.name), findsOneWidget);
    expect(repository.calls, ['profiles', 'profile']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Chat tab exposes only source gate and retains tab on cancel', (
    tester,
  ) async {
    final repository = PublicFixture();
    await _show(tester, repository);
    await tester.tap(find.byKey(const Key('tab-2')));
    await tester.pumpAndSettle();
    expect(find.text('Sign up to chat'), findsOneWidget);
    await tester.tap(find.byKey(const Key('guest-sign-up-chat')));
    await tester.pumpAndSettle();
    await _dismiss(tester);
    expect(find.text('Sign up to chat'), findsOneWidget);
    expect(repository.calls, ['profiles']);
    expect(find.byType(TextField), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tab switches and cancelled gate retain search/filter/scroll', (
    tester,
  ) async {
    final repository = _ManyPeople();
    await _show(tester, repository);
    await tester.enterText(
      find.byKey(const Key('skill-search-field')),
      'Design',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('skill-filter-hiring')));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('skill-search-results'));
    await tester.drag(list, const Offset(0, -650));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first,
    );
    final offset = scroll.position.pixels;
    expect(offset, greaterThan(0));
    final calls = repository.calls.length;
    await tester.tap(find.byKey(const Key('tab-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('guest-sign-up-chat')));
    await tester.pumpAndSettle();
    await _dismiss(tester);
    await tester.tap(find.byKey(const Key('tab-0')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('skill-search-field')))
          .controller!
          .text,
      'Design',
    );
    expect(scroll.position.pixels, closeTo(offset, .5));
    final filter = find
        .ancestor(
          of: find.byKey(const Key('skill-filter-hiring')),
          matching: find.byType(Semantics),
        )
        .first;
    expect(tester.widget<Semantics>(filter).properties.selected, isTrue);
    expect(repository.calls.length, calls);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('P16 Hiring uses real requests and source headings/pagination', (
    tester,
  ) async {
    final repository = _DatedRequests();
    await _show(tester, repository);
    await tester.tap(find.byKey(const Key('tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Last week'), findsOneWidget);
    expect(find.text('Earlier'), findsNothing);
    expect(tester.widget<Text>(find.text('Today')).style!.fontSize, 12);
    expect(find.text('Publish request'), findsNothing);
    expect(find.text('Skill Search'), findsNothing);
    await tester.drag(
      find.byKey(const Key('community-feed')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Actual skill 10', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('More hiring'), findsOneWidget);
    await tester.tap(find.text('More hiring'));
    await tester.pumpAndSettle();
    expect(repository.calls.where((c) => c == 'feed').length, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelled handoff keeps the originating public Hiring request', (
    tester,
  ) async {
    final repository = PublicFixture();
    await _show(tester, repository);
    await tester.tap(find.byKey(const Key('tab-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('community-${repository.hiring.id}')));
    await tester.pumpAndSettle();
    expect(find.text(repository.hiring.message), findsOneWidget);
    await tester.tap(find.text('Message author'));
    await tester.pumpAndSettle();
    expect(find.byType(GuestAppPrompt), findsOneWidget);
    await _dismiss(tester);
    expect(find.text(repository.hiring.message), findsOneWidget);
    expect(find.text('Message author'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('community-feed')), findsOneWidget);
    expect(repository.calls.where((c) => c == 'feed').length, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
