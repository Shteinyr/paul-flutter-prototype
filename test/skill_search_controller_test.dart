import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/search/skill_search_controller.dart';

const marketing = SkillSuggestion(key: 'marketing', label: 'Marketing');
const digital = SkillSuggestion(
  key: 'digital marketing',
  label: 'Digital Marketing',
);
SkillSearchHit hit(String id) => SkillSearchHit(
  id: id,
  name: id,
  occupation: 'Designer',
  matchedKinds: {SkillSearchKind.offering},
);
SkillSearchPage page(
  String query,
  SkillSearchKind kind,
  List<String> ids, {
  Map<String, dynamic>? cursor,
}) => SkillSearchPage(
  query: query,
  kind: kind,
  results: ids.map(hit).toList(),
  nextCursor: cursor,
);

class SearchRepository implements SkillSearchRepository {
  @override
  String get userId => 'a';
  @override
  String? currentUserId = 'a';
  final identities = StreamController<String?>.broadcast(sync: true);
  final suggestions = <(String, SkillSearchKind)>[];
  final searches = <(String, SkillSearchKind, Map<String, dynamic>?)>[];
  Future<List<SkillSuggestion>> Function(String, SkillSearchKind)? suggesting;
  Future<SkillSearchPage> Function(
    String,
    SkillSearchKind,
    Map<String, dynamic>?,
  )?
  searching;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Future<List<SkillSuggestion>> suggest(
    String query,
    SkillSearchKind kind,
  ) async {
    suggestions.add((query, kind));
    return suggesting == null ? [marketing, digital] : suggesting!(query, kind);
  }

  @override
  Future<SkillSearchPage> search(
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
  }) async {
    searches.add((query, kind, cursor));
    return searching == null
        ? page(query, kind, ['1'])
        : searching!(query, kind, cursor);
  }
}

Future<void> settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  late SearchRepository repository;
  late SkillSearchController controller;
  setUp(() {
    repository = SearchRepository();
    controller = SkillSearchController(repository, debounce: Duration.zero);
  });
  tearDown(() async {
    controller.dispose();
    await repository.identities.close();
  });

  test('idle is read-free and whitespace input clears all state', () async {
    expect(controller.kind, SkillSearchKind.all);
    expect(controller.idle, isTrue);
    controller.setQuery('mar');
    await settle();
    expect(controller.suggestions.length, 2);
    controller.setQuery('  ');
    await settle();
    expect(controller.suggestions, isEmpty);
    expect(controller.results, isEmpty);
    expect(controller.loading, isFalse);
    expect(repository.suggestions.length, 1);
  });

  test(
    'late suggestions cannot replace a newer query or a selected skill',
    () async {
      final old = Completer<List<SkillSuggestion>>();
      repository.suggesting = (q, k) =>
          q == 'mar' ? old.future : Future.value([digital]);
      controller.setQuery('mar');
      await settle();
      controller.setQuery('digital');
      await settle();
      await controller.select(digital);
      old.complete([marketing]);
      await settle();
      expect(controller.selected, digital);
      expect(controller.suggestions, isEmpty);
      expect(controller.results.single.id, '1');
      expect(repository.searches.single.$1, 'digital marketing');
    },
  );

  test(
    'kind change re-queries selected skill and drops stale results',
    () async {
      final old = Completer<SkillSearchPage>();
      repository.searching = (q, k, c) => k == SkillSearchKind.all
          ? old.future
          : Future.value(page(q, k, ['hiring']));
      final initial = controller.select(marketing);
      controller.setKind(SkillSearchKind.hiring);
      await settle();
      old.complete(page('marketing', SkillSearchKind.all, ['old']));
      await initial;
      expect(controller.results.single.id, 'hiring');
      expect(repository.searches.last.$2, SkillSearchKind.hiring);
      expect(repository.searches.last.$3, isNull);
    },
  );

  test('filter also applies to suggestions', () async {
    controller.setQuery('mar');
    await settle();
    controller.setKind(SkillSearchKind.offering);
    await settle();
    expect(repository.suggestions.last, ('mar', SkillSearchKind.offering));
    expect(controller.selected, isNull);
  });

  test(
    'server errors remain retryable errors while true empty stays empty',
    () async {
      repository.searching = (q, k, c) async =>
          throw const SkillSearchException('server_unavailable');
      await controller.select(marketing);
      expect(controller.error, contains('Could not search'));
      expect(controller.results, isEmpty);
      repository.searching = (q, k, c) async => page(q, k, []);
      await controller.retry();
      expect(controller.error, isNull);
      expect(controller.results, isEmpty);
      expect(controller.selected, marketing);
    },
  );

  test('suggestion failure is separate from empty and retry works', () async {
    repository.suggesting = (q, k) async =>
        throw StateError('private internal error');
    controller.setQuery('mar');
    await settle();
    expect(controller.error, contains('Could not search'));
    expect(controller.error, isNot(contains('private')));
    repository.suggesting = (q, k) async => [marketing];
    await controller.retry();
    expect(controller.error, isNull);
    expect(controller.suggestions.single, marketing);
  });

  test(
    'pagination uses canonical query, keeps order and retries same cursor',
    () async {
      final cursor = {'query': 'marketing', 'kind': 'all', 'after': '1'};
      repository.searching = (q, k, c) async => c == null
          ? page('marketing', k, ['1'], cursor: cursor)
          : throw const SkillSearchException('server_unavailable');
      await controller.select(
        const SkillSuggestion(key: ' MARKETING ', label: 'Marketing'),
      );
      await controller.loadMore();
      expect(controller.results.single.id, '1');
      expect(controller.pageError, isNotNull);
      expect(controller.error, isNull);
      repository.searching = (q, k, c) async =>
          page('marketing', k, ['1', '2']);
      await controller.loadMore();
      expect(repository.searches.last.$1, 'marketing');
      expect(repository.searches.last.$3, cursor);
      expect(controller.results.map((hit) => hit.id), ['1', '2']);
      expect(controller.hasMore, isFalse);
      expect(controller.pageError, isNull);
    },
  );

  test('query change drops late page and resets cursor', () async {
    final pending = Completer<SkillSearchPage>();
    repository.searching = (q, k, c) async =>
        c == null ? page(q, k, ['1'], cursor: {'after': '1'}) : pending.future;
    await controller.select(marketing);
    final more = controller.loadMore();
    controller.setQuery('design');
    pending.complete(page('marketing', SkillSearchKind.all, ['2']));
    await more;
    expect(controller.results, isEmpty);
    expect(controller.hasMore, isFalse);
    expect(controller.loadingMore, isFalse);
    await settle();
  });

  test(
    'A to B to A permanently invalidates old controller and pending responses',
    () async {
      final pending = Completer<SkillSearchPage>();
      repository.searching = (q, k, c) => pending.future;
      final search = controller.select(marketing);
      repository.currentUserId = 'b';
      repository.identities.add('b');
      repository.currentUserId = 'a';
      repository.identities.add('a');
      pending.complete(page('marketing', SkillSearchKind.all, ['private']));
      await search;
      expect(controller.results, isEmpty);
      expect(controller.selected, isNull);
      expect(controller.error, contains('sign in'));
      controller.setQuery('mar');
      await settle();
      expect(repository.suggestions, isEmpty);
    },
  );

  test(
    'unknown exact skill is submitted unchanged and never substituted',
    () async {
      controller.setQuery('Unknown skill');
      await controller.submit();
      expect(repository.searches.single.$1, 'Unknown skill');
      expect(controller.selected!.label, 'Unknown skill');
    },
  );
}
