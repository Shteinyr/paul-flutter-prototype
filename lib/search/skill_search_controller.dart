import 'dart:async';

import 'package:flutter/foundation.dart';

import '../skills/skill_catalogue.dart';
import 'skill_search_api.dart';

class SkillSearchController extends ChangeNotifier {
  SkillSearchController(
    this.repository, {
    this.debounce = const Duration(milliseconds: 250),
    Future<List<SkillSuggestion>> Function(String)? localSuggest,
  }) : _localSuggest = localSuggest ?? SkillCatalogue.shared.suggest {
    _identity = repository.identityChanges.listen((userId) {
      if (userId != repository.userId) _invalidate();
    }, onError: (Object _) => _identityError());
  }
  final SkillSearchRepository repository;
  final Duration debounce;
  final Future<List<SkillSuggestion>> Function(String) _localSuggest;
  List<SkillSuggestion> _local = const [];
  List<SkillSuggestion> _remote = const [];
  late final StreamSubscription<String?> _identity;
  Timer? _timer;
  int _revision = 0;
  bool _disposed = false;
  bool _authorized = true;
  String query = '';
  SkillSearchKind kind = SkillSearchKind.all;
  SkillSuggestion? selected;
  bool searchingNames = false;
  bool get hasSelection => selected != null || searchingNames;
  bool get canSearchNames =>
      repository is ProfileNameSearchRepository &&
      query.trim().runes.length >= 2;
  List<SkillSuggestion> suggestions = const [];
  List<SkillSearchHit> results = const [];
  Map<String, dynamic>? _nextCursor;
  String? _canonicalQuery;
  bool loading = false;
  bool loadingMore = false;
  String? error;
  String? pageError;
  bool get hasMore => _nextCursor != null;
  bool get idle => query.trim().isEmpty;

  bool _current(int revision) =>
      !_disposed &&
      _authorized &&
      revision == _revision &&
      repository.currentUserId == repository.userId;

  void _invalidate() {
    if (_disposed) return;
    _authorized = false;
    _reset();
    query = '';
    error = const SkillSearchException('sign_in_required').toString();
    notifyListeners();
  }

  void _reset() {
    _timer?.cancel();
    _revision++;
    suggestions = const [];
    _local = const [];
    _remote = const [];
    results = const [];
    _nextCursor = null;
    _canonicalQuery = null;
    loading = false;
    loadingMore = false;
    error = null;
    pageError = null;
    selected = null;
    searchingNames = false;
  }

  void _identityError() {
    if (_disposed || !_authorized) return;
    if (repository.currentUserId != repository.userId) {
      _invalidate();
      return;
    }
    final skill = selected;
    final names = searchingNames;
    _reset();
    selected = skill;
    searchingNames = names;
    error = const SkillSearchException('server_unavailable').toString();
    notifyListeners();
  }

  void setQuery(String value, {bool refresh = false}) {
    if (!_authorized || _disposed) return;
    if (!refresh && value == query && !hasSelection && error == null) return;
    _reset();
    query = value;
    loading = !idle;
    notifyListeners();
    if (idle) return;
    final revision = _revision;
    unawaited(_suggestLocal(revision));
    _timer = Timer(debounce, () => unawaited(_suggest(revision)));
  }

  Future<void> _suggestLocal(int revision) async {
    try {
      final items = await _localSuggest(query);
      if (!_current(revision)) return;
      _local = items;
      _mergeSuggestions();
      notifyListeners();
    } catch (_) {
      // The remote source and free text remain available if the asset fails.
    }
  }

  void _mergeSuggestions() {
    suggestions = List.unmodifiable(
      mergeSkillSuggestions([..._remote, ..._local], query),
    );
  }

  Future<void> _suggest(int revision) async {
    if (!_current(revision)) return;
    try {
      final items = await repository.suggest(query, kind);
      if (!_current(revision)) return;
      _remote = items;
      _mergeSuggestions();
    } catch (failure) {
      if (!_current(revision)) return;
      error = _message(failure);
    }
    if (!_current(revision)) return;
    loading = false;
    notifyListeners();
  }

  Future<void> select(SkillSuggestion skill) async {
    if (!_authorized || _disposed || skill.key.trim().isEmpty) return;
    _reset();
    selected = skill;
    query = skill.label;
    loading = true;
    final revision = _revision;
    notifyListeners();
    try {
      final page = await repository.search(skill.key, kind);
      if (!_current(revision)) return;
      if (page.kind != (searchingNames ? SkillSearchKind.all : kind)) {
        throw const SkillSearchException('server_unavailable');
      }
      _canonicalQuery = page.query;
      results = List.unmodifiable(page.results);
      _nextCursor = page.nextCursor;
    } catch (failure) {
      if (!_current(revision)) return;
      error = _message(failure);
    }
    if (!_current(revision)) return;
    loading = false;
    notifyListeners();
  }

  Future<void> selectName(String value) async {
    final source = repository;
    if (!_authorized ||
        _disposed ||
        source is! ProfileNameSearchRepository ||
        value.trim().runes.length < 2) {
      return;
    }
    _reset();
    query = value.trim();
    searchingNames = true;
    loading = true;
    final revision = _revision;
    notifyListeners();
    try {
      final page = await (source as ProfileNameSearchRepository).searchNames(
        query,
      );
      if (!_current(revision)) return;
      if (page.kind != SkillSearchKind.all) {
        throw const SkillSearchException('server_unavailable');
      }
      _canonicalQuery = page.query;
      results = List.unmodifiable(page.results);
      _nextCursor = page.nextCursor;
    } catch (failure) {
      if (!_current(revision)) return;
      error = _message(failure);
    }
    if (!_current(revision)) return;
    loading = false;
    notifyListeners();
  }

  Future<void> submit() => select(SkillSuggestion(key: query, label: query));

  void setKind(SkillSearchKind value) {
    if (value == kind || searchingNames || !_authorized || _disposed) return;
    final skill = selected;
    kind = value;
    if (skill == null) {
      setQuery(query, refresh: true);
    } else {
      unawaited(select(skill));
    }
  }

  Future<void> retry() async {
    final skill = selected;
    if (searchingNames) {
      await selectName(query);
    } else if (skill != null) {
      await select(skill);
    } else if (!idle && _authorized && !_disposed) {
      _timer?.cancel();
      error = null;
      loading = true;
      final revision = ++_revision;
      unawaited(_suggestLocal(revision));
      notifyListeners();
      await _suggest(revision);
    }
  }

  Future<void> loadMore() async {
    final cursor = _nextCursor;
    final canonicalQuery = _canonicalQuery;
    if (!_current(_revision) ||
        loading ||
        loadingMore ||
        cursor == null ||
        canonicalQuery == null) {
      return;
    }
    final revision = _revision;
    loadingMore = true;
    pageError = null;
    notifyListeners();
    try {
      final page = searchingNames
          ? await (repository as ProfileNameSearchRepository).searchNames(
              canonicalQuery,
              cursor: cursor,
            )
          : await repository.search(canonicalQuery, kind, cursor: cursor);
      if (!_current(revision)) return;
      if (page.query != canonicalQuery ||
          page.kind != (searchingNames ? SkillSearchKind.all : kind)) {
        throw const SkillSearchException('server_unavailable');
      }
      final ids = results.map((hit) => hit.id).toSet();
      results = List.unmodifiable([
        ...results,
        ...page.results.where((hit) => ids.add(hit.id)),
      ]);
      _nextCursor = page.nextCursor;
    } catch (failure) {
      if (!_current(revision)) return;
      pageError = _message(failure);
    }
    if (!_current(revision)) return;
    loadingMore = false;
    notifyListeners();
  }

  String _message(Object error) => error is SkillSearchException
      ? error.toString()
      : const SkillSearchException('server_unavailable').toString();

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    _timer?.cancel();
    unawaited(_identity.cancel());
    super.dispose();
  }
}
