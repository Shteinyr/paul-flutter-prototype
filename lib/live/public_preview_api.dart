import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../community/community_api.dart';
import '../search/skill_search_api.dart';
import '../skills/skill_catalogue.dart';
import '../profile/user_profile.dart';
import 'chat_api.dart';
import 'member_capabilities.dart';
import 'public_preview_bootstrap.dart';

class PublicProfile {
  const PublicProfile({
    required this.id,
    required this.profile,
    this.avatarUrl,
    this.contactCount = 0,
  });
  final String id;
  final UserProfile profile;
  final String? avatarUrl;
  final int contactCount;
  factory PublicProfile.fromJson(Map<String, dynamic> value) => PublicProfile(
    id: value['id'] as String,
    profile: UserProfile(
      name: value['name'] as String,
      occupation: value['occupation'] as String,
      summary: value['summary'] as String,
      skills: List<String>.from(value['skills'] as List),
      searchingSkills: List<String>.from(value['searching_skills'] as List),
    ),
    avatarUrl: value['avatar_url'] as String?,
    contactCount: value['contact_count'] as int? ?? 0,
  );
}

class PublicProfilePage {
  const PublicProfilePage(this.profiles, this.query, this.nextCursor);
  final List<PublicProfile> profiles;
  final String query;
  final Map<String, dynamic>? nextCursor;
}

abstract interface class PublicPreviewRepository {
  Future<PublicProfilePage> profiles({
    String query = '',
    SkillSearchKind kind = SkillSearchKind.all,
    Map<String, dynamic>? cursor,
    bool namesOnly = false,
  });
  Future<PublicProfile?> profile(String id);
  PublicProfile? cachedProfile(String id);
  Future<CommunityPage> feed({Map<String, dynamic>? cursor});
  Future<CommunityRequest?> request(String id);
}

/// This transport intentionally sends no user session, even while Auth is refreshing.
class PublicPreviewApi implements PublicPreviewRepository {
  PublicPreviewApi({
    required this.url,
    required this.publishableKey,
    http.Client? transport,
    Future<String?> Function(Uri url, String key)? bootstrap,
  }) : _transport = transport ?? http.Client(),
       _bootstrap = bootstrap ?? takePublicPreviewBootstrap;
  final Uri url;
  final String publishableKey;
  final http.Client _transport;
  final Future<String?> Function(Uri url, String key) _bootstrap;
  bool _bootstrapChecked = false;
  final _profiles = <String, PublicProfile>{};
  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    final response = await _transport
        .post(
          url.resolve('/functions/v1/public-preview'),
          // This intentionally anonymous, read-only endpoint has verify_jwt=false.
          // Safelisted text/plain carries the same bounded JSON body without a
          // serial CORS preflight. Never copy this transport to private APIs.
          headers: {'Content-Type': 'text/plain;charset=UTF-8'},
          body: jsonEncode({'action': action, ...fields}),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      throw const FormatException('Public content unavailable');
    }
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  PublicProfile _remember(Map<String, dynamic> value) {
    final profile = PublicProfile.fromJson(value);
    _profiles.remove(profile.id);
    _profiles[profile.id] = profile;
    while (_profiles.length > 128) {
      _profiles.remove(_profiles.keys.first);
    }
    return profile;
  }

  @override
  PublicProfile? cachedProfile(String id) => _profiles[id];
  @override
  Future<PublicProfilePage> profiles({
    String query = '',
    SkillSearchKind kind = SkillSearchKind.all,
    Map<String, dynamic>? cursor,
    bool namesOnly = false,
  }) async {
    Map<String, dynamic>? initial;
    var initialRequestFailed = false;
    if (!_bootstrapChecked &&
        !namesOnly &&
        query.isEmpty &&
        kind == SkillSearchKind.all &&
        cursor == null) {
      _bootstrapChecked = true;
      try {
        final raw = await _bootstrap(url, publishableKey);
        if (raw != null && raw.length <= 1048576) {
          final value = Map<String, dynamic>.from(jsonDecode(raw) as Map);
          if (value['__paul_bootstrap_failed'] == true) {
            initialRequestFailed = true;
          } else if (value['query'] == '' &&
              value['profiles'] is List &&
              (value['next_cursor'] == null || value['next_cursor'] is Map)) {
            // Use exactly the normal wire parser before accepting early data.
            for (final item in value['profiles'] as List) {
              PublicProfile.fromJson(Map<String, dynamic>.from(item as Map));
            }
            initial = value;
          }
        }
      } catch (_) {
        // An unavailable, malformed or expired early result falls back to the
        // ordinary public endpoint, without changing auth or error handling.
      }
    }
    if (initialRequestFailed) {
      throw const FormatException('Public content unavailable');
    }
    final data =
        initial ??
        await _call(namesOnly ? 'names' : 'profiles', {
          'query': query,
          if (!namesOnly) 'kind': kind.name,
          'cursor': ?cursor,
        });
    return PublicProfilePage(
      (data['profiles'] as List)
          .map((v) => _remember(Map<String, dynamic>.from(v as Map)))
          .toList(),
      data['query'] as String,
      data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map),
    );
  }

  @override
  Future<PublicProfile?> profile(String id) async {
    final data = await _call('profile', {'profile_id': id});
    if (data['profile'] == null) {
      _profiles.remove(id);
      return null;
    }
    return _remember(Map<String, dynamic>.from(data['profile'] as Map));
  }

  CommunityRequest _request(Map<String, dynamic> data) {
    final author = _remember(Map<String, dynamic>.from(data['author'] as Map));
    return CommunityRequest(
      id: data['id'] as String,
      author: ChatPeer(
        id: author.id,
        name: author.profile.name,
        occupation: author.profile.occupation,
      ),
      skill: data['skill'] as String,
      message: data['message'] as String,
      createdAt: DateTime.parse(data['created_at'] as String),
      expiresAt: DateTime.parse(data['expires_at'] as String),
      isAuthor: false,
    );
  }

  @override
  Future<CommunityPage> feed({Map<String, dynamic>? cursor}) async {
    final data = await _call('feed', {'cursor': ?cursor});
    return CommunityPage(
      (data['requests'] as List)
          .map((v) => _request(Map<String, dynamic>.from(v as Map)))
          .toList(),
      data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map),
      DateTime.parse(data['server_now'] as String),
    );
  }

  @override
  Future<CommunityRequest?> request(String id) async {
    final data = await _call('get', {'request_id': id});
    return data['request'] == null
        ? null
        : _request(Map<String, dynamic>.from(data['request'] as Map));
  }
}

class PublicSearchRepository
    implements SkillSearchRepository, ProfileNameSearchRepository {
  PublicSearchRepository(this.repository);
  final PublicPreviewRepository repository;
  final saved = <String, PublicProfile>{};
  void remember(Iterable<PublicProfile> profiles) {
    for (final p in profiles) {
      saved[p.id] = p;
    }
    while (saved.length > 128) {
      saved.remove(saved.keys.first);
    }
  }

  @override
  String get userId => 'public-preview';
  @override
  String get currentUserId => userId;
  @override
  Stream<String?> get identityChanges => const Stream.empty();
  @override
  Future<List<SkillSuggestion>> suggest(
    String query,
    SkillSearchKind kind,
  ) async {
    final key = skillKey(query);
    final local = saved.values
        .expand(
          (p) => [
            if (kind != SkillSearchKind.hiring) ...p.profile.skills,
            if (kind != SkillSearchKind.offering) ...p.profile.searchingSkills,
          ],
        )
        .where((s) => skillKey(s).contains(key))
        .map((s) => SkillSuggestion(key: skillKey(s), label: s));
    return mergeSkillSuggestions([
      ...local,
      ...await SkillCatalogue.shared.suggest(query),
    ], query);
  }

  Future<SkillSearchPage> _search(
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
    bool namesOnly = false,
  }) async {
    final page = await repository.profiles(
      query: query,
      kind: kind,
      cursor: cursor,
      namesOnly: namesOnly,
    );
    remember(page.profiles);
    final key = skillKey(query);
    return SkillSearchPage(
      query: page.query,
      kind: kind,
      nextCursor: page.nextCursor,
      results: page.profiles
          .map(
            (p) => SkillSearchHit(
              id: p.id,
              name: p.profile.name,
              occupation: p.profile.occupation,
              matchedKinds: {
                if (!namesOnly &&
                    p.profile.skills.any((s) => skillKey(s) == key))
                  SkillSearchKind.offering,
                if (!namesOnly &&
                    p.profile.searchingSkills.any((s) => skillKey(s) == key))
                  SkillSearchKind.hiring,
              },
            ),
          )
          .toList(),
    );
  }

  @override
  Future<SkillSearchPage> search(
    String query,
    SkillSearchKind kind, {
    Map<String, dynamic>? cursor,
  }) => _search(query, kind, cursor: cursor);
  @override
  Future<SkillSearchPage> searchNames(
    String query, {
    Map<String, dynamic>? cursor,
  }) => _search(query, SkillSearchKind.all, cursor: cursor, namesOnly: true);
}

class PublicCommunityRepository implements CommunityRepository {
  const PublicCommunityRepository(this.repository, {this.onOpenRequest});
  final PublicPreviewRepository repository;
  final void Function(String id)? onOpenRequest;
  @override
  String get userId => 'public-preview';
  @override
  String get currentUserId => userId;
  @override
  Stream<String?> get identityChanges => const Stream.empty();
  @override
  Future<CommunityPage> feed({Map<String, dynamic>? cursor}) =>
      repository.feed(cursor: cursor);
  @override
  Future<CommunityRequest?> get(String requestId) {
    onOpenRequest?.call(requestId);
    return repository.request(requestId);
  }

  @override
  Future<CommunityReceipt> create(
    String operationId,
    String skill,
    String message,
  ) => Future.error(const CommunityException('sign_in_required'));
  @override
  Future<void> close(String operationId, String requestId) =>
      Future.error(const CommunityException('sign_in_required'));
  @override
  Future<MemberCapabilities> capabilities() async => MemberCapabilities(
    invitedRegistrations: 0,
    canMessageAnyone: false,
    canPublishCommunity: false,
    offeringLimit: 5,
    newConversationsRemaining: 0,
    quotaResetsAt: DateTime.now().toUtc(),
  );
  @override
  Future<Uint8List?> photo(CommunityRequest request) async => null;
}
