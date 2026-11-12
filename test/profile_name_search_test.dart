import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/search/skill_search_controller.dart';
import 'package:paul_demo/search/skill_search_view.dart';
import 'skill_search_controller_test.dart'
    show SearchRepository, page, marketing;

class NameRepository extends SearchRepository
    implements ProfileNameSearchRepository {
  final names = <(String, Map<String, dynamic>?)>[];
  Future<SkillSearchPage> Function(String, Map<String, dynamic>?)? finding;
  @override
  Future<SkillSearchPage> searchNames(
    String q, {
    Map<String, dynamic>? cursor,
  }) async {
    names.add((q, cursor));
    return finding == null
        ? page(q.toLowerCase(), SkillSearchKind.all, ['Julia Robinson'])
        : finding!(q, cursor);
  }
}

void main() {
  late NameRepository repo;
  late SkillSearchController controller;
  setUp(() {
    repo = NameRepository();
    controller = SkillSearchController(
      repo,
      debounce: Duration.zero,
      localSuggest: (_) async => [],
    );
  });
  tearDown(() async {
    controller.dispose();
    await repo.identities.close();
  });
  test(
    'name capability requires two characters and never guesses intent',
    () async {
      controller.setQuery('j');
      expect(controller.canSearchNames, isFalse);
      await controller.selectName('j');
      expect(repo.names, isEmpty);
      controller.setQuery('Ju');
      expect(controller.canSearchNames, isTrue);
      await controller.submit();
      expect(repo.names, isEmpty);
      expect(repo.searches.single.$1, 'Ju');
      await controller.selectName(' Julia ');
      expect(repo.names.single.$1, 'Julia');
      expect(controller.searchingNames, isTrue);
      expect(controller.selected, isNull);
      expect(controller.results.single.name, 'Julia Robinson');
    },
  );
  test('names paginate by canonical query and retry same cursor', () async {
    final cursor = {'query': 'julia', 'mode': 'names', 'after': 'one'};
    repo.finding = (q, c) async => c == null
        ? page('julia', SkillSearchKind.all, ['one'], cursor: cursor)
        : throw StateError('offline');
    await controller.selectName('JULIA');
    await controller.loadMore();
    expect(controller.pageError, isNotNull);
    expect(controller.results.single.id, 'one');
    repo.finding = (q, c) async => page(q, SkillSearchKind.all, ['one', 'two']);
    await controller.loadMore();
    expect(repo.names.last, ('julia', cursor));
    expect(controller.results.map((h) => h.id), ['one', 'two']);
    expect(controller.pageError, isNull);
  });
  test(
    'name failure retries name search and skill filters cannot alter its audience',
    () async {
      repo.finding = (q, c) async => throw StateError('offline');
      await controller.selectName('Julia');
      expect(controller.error, isNotNull);
      controller.setKind(SkillSearchKind.hiring);
      expect(repo.searches, isEmpty);
      repo.finding = null;
      await controller.retry();
      expect(repo.names.length, 2);
      expect(controller.results.single.name, 'Julia Robinson');
      await controller.select(marketing);
      expect(controller.searchingNames, isFalse);
    },
  );
  for (final change in ['query', 'skill', 'identity']) {
    test('late name page is fenced after $change', () async {
      final pending = Completer<SkillSearchPage>();
      repo.finding = (q, c) => pending.future;
      final initial = controller.selectName('Julia');
      switch (change) {
        case 'query':
          controller.setQuery('Design');
        case 'skill':
          await controller.select(marketing);
        case 'identity':
          repo.currentUserId = 'b';
          repo.identities.add('b');
      }
      pending.complete(page('julia', SkillSearchKind.all, ['private']));
      await initial;
      expect(controller.results.where((h) => h.id == 'private'), isEmpty);
    });
  }
  final opened = <String>[];
  Future<void> show(WidgetTester tester) async => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: SkillSearchView(
            controller: controller,
            contacts: const Text('Contacts'),
            onOpen: (h) async {
              opened.add(h.id);
            },
            avatarFor: (_) => const CircleAvatar(),
            onAskCommunity: (_) {},
          ),
        ),
      ),
    ),
  );
  testWidgets(
    'explicit name row opens ordinary person card without skill filters',
    (tester) async {
      await show(tester);
      await tester.enterText(
        find.byKey(const Key('skill-search-field')),
        'Julia',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('search-people-by-name')));
      await tester.pumpAndSettle();
      expect(find.text('Julia Robinson'), findsOneWidget);
      expect(find.text('Designer'), findsOneWidget);
      expect(find.byKey(const Key('skill-filter-all')), findsNothing);
      expect(controller.selected, isNull);
      await tester.tap(
        find.byKey(const ValueKey('skill-result-Julia Robinson')),
      );
      await tester.pumpAndSettle();
      expect(opened, ['Julia Robinson']);
    },
  );
  testWidgets('name empty result does not offer a skill Hiring request', (
    tester,
  ) async {
    repo.finding = (q, c) async => page(q, SkillSearchKind.all, []);
    await show(tester);
    await controller.selectName('Unknown');
    await tester.pumpAndSettle();
    expect(find.text('No profiles found with this name'), findsOneWidget);
    expect(find.text('Ask our community'), findsNothing);
  });
}
