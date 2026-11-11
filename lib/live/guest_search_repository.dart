import '../profile/user_profile.dart';
import '../search/skill_search_api.dart';
import '../skills/skill_catalogue.dart';

/// In-memory sample cards only. Never receives a client, token or member data.
class GuestSearchRepository implements SkillSearchRepository {
  GuestSearchRepository(
    Map<String, UserProfile> profiles, {
    SkillCatalogue? catalogue,
  }) : profiles = Map.unmodifiable(profiles),
       _catalogue = catalogue ?? SkillCatalogue.shared;

  final Map<String, UserProfile> profiles;
  final SkillCatalogue _catalogue;
  @override
  String get userId => 'guest-preview';
  @override
  String get currentUserId => userId;
  @override
  Stream<String?> get identityChanges => const Stream.empty();

  Iterable<String> _skills(UserProfile profile, SkillSearchKind kind) => [
    if (kind != SkillSearchKind.hiring) ...profile.skills,
    if (kind != SkillSearchKind.offering) ...profile.searchingSkills,
  ];

  @override
  Future<List<SkillSuggestion>> suggest(
    String query,
    SkillSearchKind kind,
  ) async {
    final key = skillKey(query);
    final saved = mergeSkillSuggestions(
      profiles.values
          .expand((profile) => _skills(profile, kind))
          .where((label) => skillKey(label).contains(key))
          .map((label) => SkillSuggestion(key: skillKey(label), label: label)),
      query,
    );
    final catalogue = await _catalogue.suggest(query);
    return mergeSkillSuggestions([...saved, ...catalogue], query);
  }

  @override
  Future<SkillSearchPage> search(
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
  }) async {
    final key = skillKey(query);
    return SkillSearchPage(
      query: key,
      kind: kind,
      results: [
        for (final entry in profiles.entries)
          if (_skills(entry.value, kind).any((skill) => skillKey(skill) == key))
            SkillSearchHit(
              id: entry.key,
              name: entry.value.name,
              occupation: entry.value.occupation,
              matchedKinds: {
                if (kind != SkillSearchKind.hiring &&
                    entry.value.skills.any((skill) => skillKey(skill) == key))
                  SkillSearchKind.offering,
                if (kind != SkillSearchKind.offering &&
                    entry.value.searchingSkills.any(
                      (skill) => skillKey(skill) == key,
                    ))
                  SkillSearchKind.hiring,
              },
            ),
      ],
    );
  }
}
