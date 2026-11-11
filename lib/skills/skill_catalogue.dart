import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

String skillKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

class SkillSuggestion {
  const SkillSuggestion({required this.key, required this.label});
  final String key;
  final String label;
}

class SkillCatalogue {
  SkillCatalogue({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static final shared = SkillCatalogue();
  final AssetBundle _bundle;
  final Set<String> _commonKeys = {};
  Future<List<SkillSuggestion>>? _loading;

  Future<List<SkillSuggestion>> _load() => _loading ??= _read();

  Future<List<SkillSuggestion>> _read() async {
    try {
      final data =
          jsonDecode(await _bundle.loadString('assets/skills/esco_en.json'))
              as Map<String, dynamic>;
      final labels = <String, SkillSuggestion>{};
      final supplement = data['supplement'] as Map<String, dynamic>?;
      _commonKeys
        ..clear()
        ..addAll(
          (supplement?['labels'] as List? ?? []).cast<String>().map(skillKey),
        );
      final sourceLabels = [
        ...?supplement?['labels'] as List?,
        for (final entry in data['entries'] as List) (entry as List)[1],
      ];
      for (final label in sourceLabels.cast<String>()) {
        final key = skillKey(label);
        if (key.isNotEmpty && label.characters.length <= 64) {
          labels.putIfAbsent(
            key,
            () => SkillSuggestion(key: key, label: label),
          );
        }
      }
      return List.unmodifiable(labels.values);
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  Future<List<SkillSuggestion>> suggest(String query, {int limit = 10}) async {
    final key = skillKey(query);
    if (key.isEmpty) return const [];
    return _mergeSkillSuggestions(
      (await _load()).where(
        (item) =>
            item.key.contains(key) &&
            (key.length > 2 || _startsWord(item.key, key)),
      ),
      query,
      limit: limit,
      commonKeys: _commonKeys,
    );
  }
}

bool _startsWord(String label, String query) =>
    label.startsWith(query) ||
    RegExp(r'[\s/(-]')
        .allMatches(label)
        .any((separator) => label.startsWith(query, separator.end));

List<SkillSuggestion> mergeSkillSuggestions(
  Iterable<SkillSuggestion> suggestions,
  String query, {
  int limit = 10,
}) => _mergeSkillSuggestions(suggestions, query, limit: limit);

List<SkillSuggestion> _mergeSkillSuggestions(
  Iterable<SkillSuggestion> suggestions,
  String query, {
  int limit = 10,
  Set<String> commonKeys = const {},
}) {
  final key = skillKey(query);
  final unique = <String, SkillSuggestion>{};
  for (final item in suggestions) {
    unique.putIfAbsent(skillKey(item.key), () => item);
  }
  int rank(SkillSuggestion item) => item.key == key
      ? 0
      : item.key.startsWith(key)
      ? 1
      : _startsWord(item.key, key)
      ? 2
      : 3;
  final sorted = unique.values.toList()
    ..sort((a, b) {
      final order = rank(a).compareTo(rank(b));
      if (order != 0) return order;
      final common = (commonKeys.contains(a.key) ? 0 : 1).compareTo(
        commonKeys.contains(b.key) ? 0 : 1,
      );
      if (common != 0) return common;
      final length = a.key.length.compareTo(b.key.length);
      return length == 0 ? a.key.compareTo(b.key) : length;
    });
  return sorted.take(limit).toList();
}
