import 'dart:convert';
import 'dart:typed_data';

import '../profile/user_profile.dart';
import '../live/chat_api.dart';
import 'operator_chat_api.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

class AdminException implements Exception {
  const AdminException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'admin_forbidden' || 'managed_profile_forbidden' =>
      'Administrative access is unavailable for this account.',
    'profile_version_conflict' =>
      'This profile changed. Reopen it before editing.',
    'invalid_profile' => 'Check the name, summary, photo and offered skills.',
    'operation_id_conflict' =>
      'This request was already used with different changes.',
    'sign_in_required' => 'Please sign in again to continue.',
    _ => 'Could not load Admin. Check your connection and retry.',
  };
}

class AdminAccess {
  const AdminAccess(this.role, this.profiles);
  final String role;
  final List<ManagedProfile> profiles;
}

class ManagedProfile {
  const ManagedProfile({
    required this.id,
    required this.name,
    required this.canManage,
    required this.canReply,
    this.disabledAt,
    this.occupation = '',
    this.summary = '',
    this.skills = const [],
    this.searchingSkills = const [],
    this.avatarPath,
    this.updatedAt,
  });
  final String id;
  final String name;
  final String occupation;
  final String summary;
  final List<String> skills;
  final List<String> searchingSkills;
  final String? avatarPath;
  final String? updatedAt;
  UserProfile draft(Uint8List? photo) => UserProfile(
    name: name,
    occupation: occupation,
    summary: summary,
    skills: skills,
    searchingSkills: searchingSkills,
    photo: photo,
  );
  final bool canManage;
  final bool canReply;
  final DateTime? disabledAt;
  factory ManagedProfile.fromJson(Map<String, dynamic> json) => ManagedProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    canManage: json['can_manage'] as bool,
    canReply: json['can_reply'] as bool,
    occupation: json['occupation'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    skills: List<String>.from(json['skills'] as List? ?? []),
    searchingSkills: List<String>.from(json['searching_skills'] as List? ?? []),
    avatarPath: json['avatar_path'] as String?,
    updatedAt: json['updated_at'] as String?,
    disabledAt: DateTime.tryParse(json['disabled_at'] as String? ?? ''),
  );
}

abstract interface class AdminRepository {
  String get userId;
  ChatRepository operatorFor(String profileId);
  Future<AdminAccess> context();
  Future<Uint8List?> photo(ManagedProfile profile);
  Future<void> command(Map<String, dynamic> fields);
}

typedef _PortraitKey = ({
  String id,
  String path,
  String? updatedAt,
  DateTime? disabledAt,
});

class _PortraitRead {
  _PortraitRead(this.key);
  final _PortraitKey key;
  late final Future<Uint8List?> result;
  bool valid = true;
}

class SupabaseAdminApi implements AdminRepository {
  SupabaseAdminApi(this.client, this.userId);
  final SupabaseClient client;
  @override
  final String userId;
  final _portraits = <_PortraitKey, _PortraitRead>{};
  // Only unsettled downloads live here; completion always removes them.
  final _pendingPortraits = <_PortraitRead>{};
  String? _portraitSession;
  int _portraitGeneration = 0;
  int _contextGeneration = 0;

  String? get sessionIdForPortraitReuse =>
      _sessionId(client.auth.currentSession?.accessToken ?? '');

  void _invalidatePortraits() {
    for (final read in {..._portraits.values, ..._pendingPortraits}) {
      read.valid = false;
    }
    _portraits.clear();
    _portraitGeneration++;
  }

  // This claim only bounds local reuse. Authorization still uses the current
  // actor, server context checks and authenticated Storage/RLS.
  String? _sessionId(String token) {
    try {
      final claims = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
      );
      final id = claims is Map ? claims['session_id'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } on Object {
      return null;
    }
  }

  void _checkPortrait(
    _PortraitRead read,
    String? sessionId,
    String token,
    int generation,
  ) {
    _checkIdentity();
    final currentToken = client.auth.currentSession?.accessToken;
    final sameSession = sessionId == null
        ? currentToken == token
        : currentToken != null && _sessionId(currentToken) == sessionId;
    if (!read.valid || !sameSession || generation != _portraitGeneration) {
      throw const AdminException('managed_profile_forbidden');
    }
  }

  void _checkIdentity() {
    if (client.auth.currentUser?.id != userId) {
      _invalidatePortraits();
      throw const AdminException('sign_in_required');
    }
  }

  Future<Map<String, dynamic>> request(
    Map<String, dynamic> fields, {
    bool invalidatePortraitsOnDenied = true,
  }) async {
    _checkIdentity();
    final token = client.auth.currentSession?.accessToken;
    if (token == null) throw const AdminException('sign_in_required');
    final session = sessionIdForPortraitReuse ?? token;
    void checkSession() {
      _checkIdentity();
      if ((sessionIdForPortraitReuse ??
              client.auth.currentSession?.accessToken) !=
          session) {
        throw const AdminException('sign_in_required');
      }
    }

    try {
      final response = await client.functions
          .invoke(
            'admin',
            headers: {'Authorization': 'Bearer $token'},
            body: fields,
          )
          .timeout(const Duration(seconds: 25));
      checkSession();
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      checkSession();
      final details = error.details;
      final code = details is Map
          ? details['code'] as String? ?? 'server_unavailable'
          : 'server_unavailable';
      if (invalidatePortraitsOnDenied &&
          const {
            'admin_forbidden',
            'managed_profile_forbidden',
            'sign_in_required',
          }.contains(code)) {
        _invalidatePortraits();
      }
      throw AdminException(code);
    }
  }

  @override
  Future<AdminAccess> context() async {
    final generation = ++_contextGeneration;
    final token = client.auth.currentSession?.accessToken;
    final sessionId = sessionIdForPortraitReuse;
    bool current() =>
        generation == _contextGeneration &&
        (sessionId == null
            ? client.auth.currentSession?.accessToken == token
            : sessionIdForPortraitReuse == sessionId);
    try {
      // Context reads can finish out of order. Only the latest read in this
      // session may reconcile portraits or apply an access-denied result.
      final data = await request({
        'action': 'context',
      }, invalidatePortraitsOnDenied: false);
      final access = AdminAccess(
        data['role'] as String,
        (data['profiles'] as List)
            .map(
              (item) => ManagedProfile.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
      );
      if (!current()) return access;
      final allowed = {
        for (final profile in access.profiles)
          if (profile.canManage || profile.canReply) profile.id: profile,
      };
      bool stale(_PortraitKey key) {
        final profile = allowed[key.id];
        return profile == null ||
            profile.avatarPath != key.path ||
            profile.updatedAt != key.updatedAt ||
            profile.disabledAt != key.disabledAt;
      }

      for (final read in _pendingPortraits) {
        if (stale(read.key)) read.valid = false;
      }
      _portraits.removeWhere((key, read) {
        if (!stale(key)) return false;
        read.valid = false;
        return true;
      });
      return access;
    } on Object {
      if (current()) _invalidatePortraits();
      rethrow;
    }
  }

  @override
  Future<Uint8List?> photo(ManagedProfile profile) async {
    _checkIdentity();
    final token = client.auth.currentSession!.accessToken;
    final sessionId = _sessionId(token);
    if (_portraitSession != sessionId) {
      _invalidatePortraits();
      _portraitSession = sessionId;
    }
    final key = (
      id: profile.id,
      path: profile.avatarPath ?? '',
      updatedAt: profile.updatedAt,
      disabledAt: profile.disabledAt,
    );
    _portraits.removeWhere((old, read) {
      final stale = old.id == profile.id && old != key;
      if (stale) read.valid = false;
      return stale;
    });
    for (final read in _pendingPortraits) {
      if (read.key.id == profile.id && read.key != key) read.valid = false;
    }
    if (profile.avatarPath == null) return null;
    final generation = _portraitGeneration;
    var read = sessionId == null ? null : _portraits.remove(key);
    if (read == null) {
      read = _PortraitRead(key);
      final loading = read;
      _pendingPortraits.add(loading);
      read.result = () async {
        try {
          final bytes = await client.storage
              .from('avatars')
              .download(profile.avatarPath!);
          _checkPortrait(loading, sessionId, token, generation);
          return bytes;
        } finally {
          _pendingPortraits.remove(loading);
        }
      }();
    }
    if (sessionId != null) {
      _portraits[key] = read;
      while (_portraits.length > 8) {
        // Eviction bounds reuse without invalidating an already mounted read.
        _portraits.remove(_portraits.keys.first);
      }
    }
    try {
      final bytes = await read.result;
      _checkPortrait(read, sessionId, token, generation);
      return bytes;
    } on Object {
      _portraits.removeWhere((_, value) => identical(value, read));
      rethrow;
    }
  }

  @override
  Future<void> command(Map<String, dynamic> fields) async {
    try {
      await request(fields);
    } finally {
      _invalidatePortraits();
    }
  }

  @override
  ChatRepository operatorFor(String profileId) =>
      OperatorChatApi(this, profileId);
}
