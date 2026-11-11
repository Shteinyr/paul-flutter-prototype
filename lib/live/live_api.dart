import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../profile/profile_store.dart';
import '../profile/user_profile.dart';
import 'invitation_controller.dart';
import 'member_capabilities.dart';

class LiveApiException implements Exception {
  const LiveApiException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'invalid_invitation' =>
      'This invitation has expired or is no longer valid. Ask for a new QR or code.',
    'own_invitation' =>
      'This is your own invitation. Open another person’s QR or code to connect.',
    'membership_required' => 'Complete registration with an invitation first.',
    'sign_in_required' ||
    'session_revoked' => 'Please sign in again to continue.',
    'invalid_profile' =>
      'Check your name, photo, summary and offered skills, then try again.',
    'rate_limited' => 'Too many attempts. Wait a minute and try again.',
    'offering_limit_reached' => 'Invite 10 people to add more offered skills.',
    _ => 'Could not reach Paul. Check your connection and try again.',
  };
}

class MemberProfile {
  const MemberProfile({
    required this.id,
    required this.profile,
    required this.contactCount,
    this.avatarPath,
  });
  final String id;
  final UserProfile profile;
  final int contactCount;
  final String? avatarPath;

  factory MemberProfile.fromJson(Map<String, dynamic> value) => MemberProfile(
    id: value['id'] as String,
    profile: UserProfile(
      name: value['name'] as String,
      occupation: value['occupation'] as String,
      summary: value['summary'] as String,
      skills: List<String>.from(value['skills'] as List),
      searchingSkills: List<String>.from(value['searching_skills'] as List),
    ),
    contactCount: value['contact_count'] as int,
    avatarPath: value['avatar_path'] as String?,
  );
}

class MemberNetwork {
  const MemberNetwork({this.own, this.contacts = const []});
  final MemberProfile? own;
  final List<MemberProfile> contacts;
}

class LiveApi implements InvitationIssuer {
  LiveApi(this.client);
  final SupabaseClient client;

  Future<MemberCapabilities> capabilities() async {
    final userId = client.auth.currentUser?.id;
    final token = client.auth.currentSession?.accessToken;
    if (userId == null || token == null) {
      throw const LiveApiException('sign_in_required');
    }
    try {
      final response = await client.functions
          .invoke(
            'account',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': 'capabilities'},
          )
          .timeout(const Duration(seconds: 25));
      if (client.auth.currentUser?.id != userId) {
        throw const LiveApiException('sign_in_required');
      }
      return MemberCapabilities.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    } on FunctionException catch (error) {
      final details = error.details;
      throw LiveApiException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    try {
      final response = await client.functions
          .invoke('invitations', body: {'action': action, ...fields})
          .timeout(const Duration(seconds: 25));
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      final details = error.details;
      throw LiveApiException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<LiveInvitation> issue(String token) async {
    final elapsed = Stopwatch()..start();
    try {
      final data = await call('issue', {'token': token});
      final expires = DateTime.parse(data['expires_at'] as String);
      final remaining =
          expires.difference(DateTime.parse(data['server_now'] as String)) -
          elapsed.elapsed;
      if (remaining <= Duration.zero) throw InvitationRenewalRequired();
      return LiveInvitation(
        id: data['id'] as String,
        token: token,
        code: data['code'] as String,
        expiresAt: expires,
        lifetime: remaining,
      );
    } on LiveApiException catch (error) {
      if (error.code == 'invalid_invitation' ||
          error.code == 'invitation_collision') {
        throw InvitationRenewalRequired();
      }
      rethrow;
    }
  }

  @override
  Future<void> revoke(String id) async => call('revoke', {'id': id});

  Future<void> check(String credential) async =>
      call('check', {'credential': credential});

  Future<MemberNetwork> network() async {
    final data = await call('network');
    final own = data['profile'];
    return MemberNetwork(
      own: own is Map<String, dynamic> ? MemberProfile.fromJson(own) : null,
      contacts: (data['contacts'] as List)
          .map(
            (value) =>
                MemberProfile.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
    );
  }

  Future<MemberProfile> member(String profileId) async {
    final userId = client.auth.currentUser?.id;
    final token = client.auth.currentSession?.accessToken;
    if (userId == null || token == null) {
      throw const LiveApiException('sign_in_required');
    }
    try {
      final response = await client.functions
          .invoke(
            'account',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': 'profile', 'profile_id': profileId},
          )
          .timeout(const Duration(seconds: 25));
      if (client.auth.currentUser?.id != userId) {
        throw const LiveApiException('sign_in_required');
      }
      final profile = (response.data as Map)['profile'];
      return MemberProfile.fromJson(Map<String, dynamic>.from(profile as Map));
    } on FunctionException catch (error) {
      final details = error.details;
      throw LiveApiException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  Future<Map<String, dynamic>> profilePayload(
    UserProfile draft,
    String userId,
  ) async {
    String? avatarPath;
    if (draft.photo != null) {
      avatarPath = '$userId/${sha256.convert(draft.photo!).toString()}.png';
      await client.storage
          .from('avatars')
          .uploadBinary(
            avatarPath,
            draft.photo!,
            fileOptions: const FileOptions(
              contentType: 'image/png',
              upsert: true,
            ),
          );
    }
    return {
      'name': draft.name,
      'occupation': draft.occupation,
      'summary': draft.summary,
      'skills': draft.skills,
      'searching_skills': draft.searchingSkills,
      'avatar_path': avatarPath,
    };
  }

  Future<void> redeem(String credential, {UserProfile? draft}) async {
    final user = client.auth.currentUser;
    if (user == null) throw const LiveApiException('sign_in_required');
    final payload = draft == null ? null : await profilePayload(draft, user.id);
    if (client.auth.currentUser?.id != user.id) {
      throw const LiveApiException('sign_in_required');
    }
    await call('redeem', {'credential': credential, 'profile': ?payload});
  }

  Future<Uint8List?> photo(MemberProfile member) async {
    final path = member.avatarPath;
    return path == null ? null : client.storage.from('avatars').download(path);
  }
}

class SupabaseProfileStore implements ProfileStore {
  SupabaseProfileStore(this.api, this.userId);
  final LiveApi api;
  final String userId;

  void _checkSession() {
    if (api.client.auth.currentUser?.id != userId) {
      throw const LiveApiException('sign_in_required');
    }
  }

  @override
  Future<UserProfile> read() async {
    _checkSession();
    final own = (await api.network()).own;
    if (own == null) return UserProfile.empty;
    return own.profile.copyWith(photo: await api.photo(own));
  }

  @override
  Future<void> write(UserProfile profile) async {
    _checkSession();
    final payload = await api.profilePayload(profile, userId);
    _checkSession();
    await api.call('save_profile', {'profile': payload});
  }

  @override
  Future<void> clear() async => throw UnsupportedError(
    'Account deletion requires the server account workflow.',
  );
}
