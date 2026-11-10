import 'dart:typed_data';

import '../profile/user_profile.dart';
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
  Future<AdminAccess> context();
  Future<Uint8List?> photo(ManagedProfile profile);
  Future<void> command(Map<String, dynamic> fields);
}

class SupabaseAdminApi implements AdminRepository {
  const SupabaseAdminApi(this.client, this.userId);
  final SupabaseClient client;
  final String userId;

  void _checkIdentity() {
    if (client.auth.currentUser?.id != userId) {
      throw const AdminException('sign_in_required');
    }
  }

  Future<Map<String, dynamic>> _call(Map<String, dynamic> fields) async {
    _checkIdentity();
    final token = client.auth.currentSession?.accessToken;
    if (token == null) throw const AdminException('sign_in_required');
    try {
      final response = await client.functions
          .invoke(
            'admin',
            headers: {'Authorization': 'Bearer $token'},
            body: fields,
          )
          .timeout(const Duration(seconds: 25));
      _checkIdentity();
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      _checkIdentity();
      final details = error.details;
      throw AdminException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<AdminAccess> context() async {
    final data = await _call({'action': 'context'});
    return AdminAccess(
      data['role'] as String,
      (data['profiles'] as List)
          .map(
            (item) =>
                ManagedProfile.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList(),
    );
  }

  @override
  Future<Uint8List?> photo(ManagedProfile profile) async {
    _checkIdentity();
    if (profile.avatarPath == null) return null;
    final bytes = await client.storage
        .from('avatars')
        .download(profile.avatarPath!);
    _checkIdentity();
    return bytes;
  }

  @override
  Future<void> command(Map<String, dynamic> fields) async {
    await _call(fields);
  }
}
