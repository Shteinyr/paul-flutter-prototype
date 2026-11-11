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
  Future<List<SkillSuggestion>>? _loading;

  Future<List<SkillSuggestion>> _load() => _loading ??= _read();

  Future<List<SkillSuggestion>> _read() async {
    try {
      final data =
          jsonDecode(await _bundle.loadString('assets/skills/esco_en.json'))
              as Map<String, dynamic>;
      final labels = <String, SkillSuggestion>{};
      for (final entry in data['entries'] as List) {
        final label = (entry as List)[1] as String;
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
    return mergeSkillSuggestions(
      (await _load()).where((item) => item.key.contains(key)),
      query,
      limit: limit,
    );
  }
}

List<SkillSuggestion> mergeSkillSuggestions(
  Iterable<SkillSuggestion> suggestions,
  String query, {
  int limit = 10,
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
      : 2;
  final sorted = unique.values.toList()
    ..sort((a, b) {
      final order = rank(a).compareTo(rank(b));
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
  return sorted.take(limit).toList();
}
