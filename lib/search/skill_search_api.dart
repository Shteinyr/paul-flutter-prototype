import 'package:supabase_flutter/supabase_flutter.dart';

import '../skills/skill_catalogue.dart';
export '../skills/skill_catalogue.dart' show SkillSuggestion;

enum SkillSearchKind {
  all('All'),
  offering('Offering'),
  hiring('Hiring');

  const SkillSearchKind(this.label);
  final String label;
}

class SkillSearchException implements Exception {
  const SkillSearchException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'sign_in_required' ||
    'session_revoked' => 'Please sign in again to search.',
    'membership_required' => 'Complete registration with an invitation first.',
    'rate_limited' => 'Too many searches. Wait a minute and try again.',
    'invalid_request' => 'Check your search and try again.',
    _ => 'Could not search. Check your connection and try again.',
  };
}

class MutualContact {
  const MutualContact({
    required this.id,
    required this.name,
    required this.occupation,
    this.avatarPath,
  });
  final String id;
  final String name;
  final String occupation;
  final String? avatarPath;
  factory MutualContact.fromJson(Map<String, dynamic> data) => MutualContact(
    id: data['id'] as String,
    name: data['name'] as String,
    occupation: data['occupation'] as String,
    avatarPath: data['avatar_path'] as String?,
  );
}

class SkillSearchHit {
  const SkillSearchHit({
    required this.id,
    required this.name,
    required this.occupation,
    required this.matchedKinds,
    this.mutualContacts = const [],
    this.mutualContactCount = 0,
  });
  final String id;
  final String name;
  final String occupation;
  final Set<SkillSearchKind> matchedKinds;
  final List<MutualContact> mutualContacts;
  final int mutualContactCount;
}

class SkillSearchPage {
  const SkillSearchPage({
    required this.query,
    required this.kind,
    required this.results,
    this.nextCursor,
  });
  final String query;
  final SkillSearchKind kind;
  final List<SkillSearchHit> results;
  final Map<String, dynamic>? nextCursor;
}

abstract interface class SkillSearchRepository {
  String get userId;
  String? get currentUserId;
  Stream<String?> get identityChanges;
  Future<List<SkillSuggestion>> suggest(String query, SkillSearchKind kind);
  Future<SkillSearchPage> search(
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
  });
}

abstract interface class ProfileNameSearchRepository {
  Future<SkillSearchPage> searchNames(
    String query, {
    Map<String, dynamic>? cursor,
  });
}

class SupabaseSkillSearchApi
    implements SkillSearchRepository, ProfileNameSearchRepository {
  SupabaseSkillSearchApi(this.client, this.userId);
  final SupabaseClient client;
  @override
  final String userId;
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Stream<String?> get identityChanges =>
      client.auth.onAuthStateChange.map((event) => event.session?.user.id);

  void _checkIdentity() {
    if (currentUserId != userId) {
      throw const SkillSearchException('sign_in_required');
    }
  }

  Future<Map<String, dynamic>> _call(
    String action,
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
  }) async {
    _checkIdentity();
    final initiatingToken = client.auth.currentSession?.accessToken;
    if (initiatingToken == null) {
      throw const SkillSearchException('sign_in_required');
    }
    try {
      final response = await client.functions
          .invoke(
            'skill-search',
            headers: {'Authorization': 'Bearer $initiatingToken'},
            body: {
              'action': action,
              'query': query,
              'kind': kind.name,
              'cursor': ?cursor,
            },
          )
          .timeout(const Duration(seconds: 25));
      _checkIdentity();
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      _checkIdentity();
      final details = error.details;
      throw SkillSearchException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    } catch (_) {
      _checkIdentity();
      throw const SkillSearchException('server_unavailable');
    }
  }

  @override
  Future<List<SkillSuggestion>> suggest(
    String query,
    SkillSearchKind kind,
  ) async {
    final data = await _call('suggest', query, kind);
    final saved = (data['suggestions'] as List).map((value) {
      final item = value as Map;
      return SkillSuggestion(
        key: item['key'] as String,
        label: item['label'] as String,
      );
    }).toList();
    final catalogue = await SkillCatalogue.shared.suggest(query);
    _checkIdentity();
    return mergeSkillSuggestions([...saved, ...catalogue], query);
  }

  @override
  Future<SkillSearchPage> search(
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
  }) async {
    return _page(await _call('search', query, kind, cursor: cursor));
  }

  @override
  Future<SkillSearchPage> searchNames(
    String query, {
    Map<String, dynamic>? cursor,
  }) async => _page(
    await _call('search_names', query, SkillSearchKind.all, cursor: cursor),
  );

  SkillSearchPage _page(Map<String, dynamic> data) {
    return SkillSearchPage(
      query: data['query'] as String,
      kind: SkillSearchKind.values.byName(data['kind'] as String),
      nextCursor: data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map),
      results: (data['results'] as List).map((value) {
        final item = value as Map;
        return SkillSearchHit(
          id: item['id'] as String,
          name: item['name'] as String,
          occupation: item['occupation'] as String,
          mutualContacts: List.unmodifiable(
            (item['mutual_contacts'] as List? ?? const [])
                .take(3)
                .map(
                  (v) => MutualContact.fromJson(
                    Map<String, dynamic>.from(v as Map),
                  ),
                ),
          ),
          mutualContactCount: item['mutual_contact_count'] as int? ?? 0,
          matchedKinds: (item['matched_kinds'] as List)
              .map((value) => SkillSearchKind.values.byName(value as String))
              .toSet(),
        );
      }).toList(),
    );
  }
}
