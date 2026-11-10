import 'package:supabase_flutter/supabase_flutter.dart';

class AdminException implements Exception {
  const AdminException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'admin_forbidden' || 'managed_profile_forbidden' =>
      'Administrative access is unavailable for this account.',
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
  });
  final String id;
  final String name;
  final bool canManage;
  final bool canReply;
  final DateTime? disabledAt;
  factory ManagedProfile.fromJson(Map<String, dynamic> json) => ManagedProfile(
    id: json['id'] as String,
    name: json['name'] as String,
    canManage: json['can_manage'] as bool,
    canReply: json['can_reply'] as bool,
    disabledAt: DateTime.tryParse(json['disabled_at'] as String? ?? ''),
  );
}

abstract interface class AdminRepository {
  Future<AdminAccess> context();
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

  @override
  Future<AdminAccess> context() async {
    _checkIdentity();
    final token = client.auth.currentSession?.accessToken;
    if (token == null) throw const AdminException('sign_in_required');
    try {
      final response = await client.functions
          .invoke(
            'admin',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': 'context'},
          )
          .timeout(const Duration(seconds: 25));
      _checkIdentity();
      final data = Map<String, dynamic>.from(response.data as Map);
      return AdminAccess(
        data['role'] as String,
        (data['profiles'] as List)
            .map(
              (item) => ManagedProfile.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(),
      );
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
}
