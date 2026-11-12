import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/search/skill_search_controller.dart';
import 'package:paul_demo/search/skill_search_view.dart';

import 'skill_search_controller_test.dart'
    show SearchRepository, marketing, digital, page;

void main() {
  late SearchRepository repository;
  late SkillSearchController controller;
  setUp(() {
    repository = SearchRepository();
    controller = SkillSearchController(
      repository,
      debounce: Duration.zero,
      localSuggest: (_) async => [],
    );
  });
  tearDown(() async {
    controller.dispose();
    await repository.identities.close();
  });
  final communitySkills = <String>[];
  Future<void> show(
    WidgetTester tester, {
    double width = 403,
    bool community = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SkillSearchView(
                controller: controller,
                contacts: const Text('Existing contacts'),
                onOpen: (_) async {},
                avatarFor: (_) => const CircleAvatar(radius: 32.5),
                onAskCommunity: community ? communitySkills.add : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'idle Contacts, suggestions, selected result and clear follow normal field flow',
    (tester) async {
      await show(tester);
      expect(find.text('Existing contacts'), findsOneWidget);
      expect(repository.suggestions, isEmpty);
      await tester.enterText(
        find.byKey(const Key('skill-search-field')),
        'mar',
      );
      await tester.pumpAndSettle();
      expect(find.text('Existing contacts'), findsOneWidget);
      expect(find.byKey(const Key('skill-suggestions')), findsOneWidget);
      expect(find.byKey(const Key('skill-filter-all')), findsNothing);
      expect(find.byIcon(Icons.north_west), findsNothing);
      expect(find.text('Skill catalogue source'), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Marketing'),
        findsOneWidget,
      );
      expect(find.text('Digital Marketing'), findsOneWidget);
      await tester.tap(find.text('Marketing'));
      await tester.pumpAndSettle();
      expect(repository.searches.single.$1, 'marketing');
      expect(find.byKey(const ValueKey('skill-result-1')), findsOneWidget);
      await tester.tap(find.byTooltip('Clear skill search'));
      await tester.pumpAndSettle();
      expect(find.text('Existing contacts'), findsOneWidget);
      expect(controller.kind, SkillSearchKind.all);
    },
  );

  testWidgets(
    'result labels and highlights follow All Offer Hiring without duplicate matches',
    (tester) async {
      repository.searching = (q, k, c) async => SkillSearchPage(
        query: q,
        kind: k,
        results: const [
          SkillSearchHit(
            id: 'both',
            name: 'Julia',
            occupation: 'Designer',
            matchedKinds: {SkillSearchKind.offering, SkillSearchKind.hiring},
          ),
        ],
      );
      await show(tester);
      await controller.select(marketing);
      await tester.pumpAndSettle();
      expect(find.text('Offer'), findsOneWidget);
      expect(find.text('Offer: '), findsNothing);
      expect(find.text('Hiring: '), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == 'Marketing'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('skill-filter-offering')));
      await tester.pumpAndSettle();
      expect(find.text('Offer: '), findsOneWidget);
      await tester.tap(find.byKey(const Key('skill-filter-hiring')));
      await tester.pumpAndSettle();
      expect(find.text('Hiring: '), findsOneWidget);
      final label = find.byWidgetPredicate(
        (w) => w is Text && w.data == 'Marketing',
      );
      final highlight = find
          .ancestor(of: label, matching: find.byType(Container))
          .first;
      expect(
        tester.widget<Container>(highlight).color,
        const Color(0xFFFFBFBC),
      );
      expect(find.text('Julia'), findsOneWidget);
    },
  );

  for (final width in [320.0, 390.0]) {
    testWidgets('dropdown overlays Contacts within keyboard space at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 640);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await show(tester, width: width);
      await tester.enterText(
        find.byKey(const Key('skill-search-field')),
        'mar',
      );
      await tester.pumpAndSettle();
      final panel = tester.getRect(find.byKey(const Key('skill-suggestions')));
      final field = tester.getRect(find.byKey(const Key('skill-search-field')));
      expect(panel.top, greaterThanOrEqualTo(field.bottom));
      expect(panel.height, lessThanOrEqualTo(192));
      expect(panel.bottom, lessThanOrEqualTo(360));
      expect(find.text('Existing contacts'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('loading, server error, retry and true empty stay distinct', (
    tester,
  ) async {
    final pending = Completer<SkillSearchPage>();
    repository.searching = (q, k, c) => pending.future;
    await show(tester);
    unawaited(controller.select(marketing));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(const SkillSearchException('server_unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('Retry search'), findsOneWidget);
    expect(find.text('No profiles found for this skill'), findsNothing);
    repository.searching = (q, k, c) async => page(q, k, []);
    await tester.tap(find.text('Retry search'));
    await tester.pumpAndSettle();
    expect(find.text('No profiles found for this skill'), findsOneWidget);
    expect(find.text('Retry search'), findsNothing);
    expect(find.textContaining('Community'), findsNothing);
  });

  testWidgets('empty search opens community with the selected skill', (
    tester,
  ) async {
    repository.searching = (q, k, c) async => page(q, k, []);
    await show(tester, community: true);
    await controller.select(marketing);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ask our community'));
    expect(communitySkills, ['Marketing']);
  });

  testWidgets(
    'filters requery and pagination appends through visible controls',
    (tester) async {
      repository.searching = (q, k, c) async => c == null
          ? page(q, k, ['1'], cursor: {'after': '1'})
          : page(q, k, ['2']);
      await show(tester);
      await controller.select(digital);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('skill-filter-hiring')));
      await tester.pumpAndSettle();
      expect(repository.searches.last.$2, SkillSearchKind.hiring);
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('skill-result-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('skill-result-2')), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    },
  );

  testWidgets('narrow layout and long legacy skill strings remain bounded', (
    tester,
  ) async {
    await show(tester, width: 320);
    await controller.select(
      SkillSuggestion(
        key: 'long',
        label: List.filled(300, 'Long skill ').join(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('skill-result-1')), findsOneWidget);
  });
  testWidgets(
    'local rows are selectable while remote suggestions are pending',
    (tester) async {
      controller.dispose();
      final pending = Completer<List<SkillSuggestion>>();
      repository.suggesting = (_, _) => pending.future;
      controller = SkillSearchController(
        repository,
        debounce: Duration.zero,
        localSuggest: (_) async => [marketing],
      );
      await show(tester, width: 320);
      await tester.enterText(
        find.byKey(const Key('skill-search-field')),
        'mar',
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(controller.loading, isTrue);
      expect(find.byKey(const ValueKey('suggest-marketing')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('suggest-marketing')));
      await tester.pumpAndSettle();
      expect(repository.searches.single.$1, 'marketing');
      pending.complete([digital]);
      await tester.pumpAndSettle();
      expect(controller.selected, marketing);
      expect(controller.suggestions, isEmpty);
    },
  );
}
