import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

String skillKey(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

class SkillSuggestion {
  const SkillSuggestion({required this.key, required this.label})
    : _common = false;
  const SkillSuggestion._common({required this.key, required this.label})
    : _common = true;
  final String key;
  final String label;
  final bool _common;
}

class SkillCatalogue {
  SkillCatalogue({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  static final shared = SkillCatalogue();
  final AssetBundle _bundle;
  Future<List<SkillSuggestion>>? _loading;

  Future<List<SkillSuggestion>> _load() => _loading ??= _read();

  Future<List<SkillSuggestion>> _read() async {
    try {
      final data =
          jsonDecode(await _bundle.loadString('assets/skills/esco_en.json'))
              as Map<String, dynamic>;
      final labels = <String, SkillSuggestion>{};
      final supplement = data['supplement'] as Map<String, dynamic>?;
      final commonKeys = (supplement?['labels'] as List? ?? [])
          .cast<String>()
          .map(skillKey)
          .toSet();
      final sourceLabels = [
        ...?supplement?['labels'] as List?,
        for (final entry in data['entries'] as List) (entry as List)[1],
      ];
      for (final label in sourceLabels.cast<String>()) {
        final key = skillKey(label);
        if (key.isNotEmpty && label.characters.length <= 64) {
          labels.putIfAbsent(
            key,
            () => commonKeys.contains(key)
                ? SkillSuggestion._common(key: key, label: label)
                : SkillSuggestion(key: key, label: label),
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
    return mergeSkillSuggestions(
      (await _load()).where(
        (item) =>
            item.key.contains(key) &&
            (key.length > 2 || _startsWord(item.key, key)),
      ),
      query,
      limit: limit,
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
}) {
  final key = skillKey(query);
  final unique = <String, SkillSuggestion>{};
  for (final item in suggestions) {
    final normalized = skillKey(item.key);
    final existing = unique.putIfAbsent(normalized, () => item);
    if (item._common && !existing._common) {
      // Keep the saved label while retaining the catalogue's ranking metadata.
      unique[normalized] = SkillSuggestion._common(
        key: existing.key,
        label: existing.label,
      );
    }
  }
  int rank(SkillSuggestion item) => item.key == key
      ? 0
      : item._common && _startsWord(item.key, key)
      ? 1
      : item.key.startsWith(key)
      ? 2
      : _startsWord(item.key, key)
      ? 3
      : 4;
  final sorted = unique.values.toList()
    ..sort((a, b) {
      final order = rank(a).compareTo(rank(b));
      if (order != 0) return order;
      final prefix = (a.key.startsWith(key) ? 0 : 1).compareTo(
        b.key.startsWith(key) ? 0 : 1,
      );
      if (prefix != 0) return prefix;
      final length = a.key.length.compareTo(b.key.length);
      return length == 0 ? a.key.compareTo(b.key) : length;
    });
  return sorted.take(limit).toList();
}
