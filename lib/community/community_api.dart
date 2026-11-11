import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../live/chat_api.dart';
import '../live/live_api.dart';
import '../live/member_capabilities.dart';

class CommunityException implements Exception {
  const CommunityException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'sign_in_required' ||
    'session_revoked' => 'Please sign in again to continue.',
    'membership_required' ||
    'community_forbidden' => 'This request is unavailable for your account.',
    'community_locked' => 'Invite 10 people to ask our community.',
    'invalid_skill' => 'Enter a skill with up to 64 characters.',
    'invalid_message' => 'Enter your request with up to 2000 characters.',
    'operation_id_conflict' =>
      'This request was already submitted with different details.',
    'rate_limited' => 'Too many attempts. Wait a minute and retry.',
    _ => 'Could not reach the community. Check your connection and retry.',
  };
}

class CommunityRequest {
  const CommunityRequest({
    required this.id,
    required this.author,
    required this.skill,
    required this.message,
    required this.createdAt,
    required this.expiresAt,
    required this.isAuthor,
  });
  final String id;
  final ChatPeer author;
  final String skill;
  final String message;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool isAuthor;

  factory CommunityRequest.fromJson(Map<String, dynamic> value) =>
      CommunityRequest(
        id: value['id'] as String,
        author: ChatPeer.fromJson(
          Map<String, dynamic>.from(value['author'] as Map),
        ),
        skill: value['skill'] as String,
        message: value['message'] as String,
        createdAt: DateTime.parse(value['created_at'] as String),
        expiresAt: DateTime.parse(value['expires_at'] as String),
        isAuthor: value['is_author'] as bool,
      );
}

class CommunityPage {
  const CommunityPage(this.requests, this.nextCursor, this.serverNow);
  final List<CommunityRequest> requests;
  final Map<String, dynamic>? nextCursor;
  final DateTime serverNow;
}

class CommunityReceipt {
  const CommunityReceipt(this.requestId, this.active);
  final String requestId;
  final bool active;
}

abstract interface class CommunityRepository {
  String get userId;
  String? get currentUserId;
  Stream<String?> get identityChanges;
  Future<CommunityPage> feed({Map<String, dynamic>? cursor});
  Future<CommunityRequest?> get(String requestId);
  Future<CommunityReceipt> create(
    String operationId,
    String skill,
    String message,
  );
  Future<void> close(String operationId, String requestId);
  Future<MemberCapabilities> capabilities();
  Future<Uint8List?> photo(CommunityRequest request);
}

class SupabaseCommunityApi implements CommunityRepository {
  const SupabaseCommunityApi(this.client, this.userId);
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
      throw const CommunityException('sign_in_required');
    }
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    _checkIdentity();
    final token = client.auth.currentSession?.accessToken;
    if (token == null) throw const CommunityException('sign_in_required');
    try {
      final response = await client.functions
          .invoke(
            'community',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': action, ...fields},
          )
          .timeout(const Duration(seconds: 25));
      _checkIdentity();
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      _checkIdentity();
      final details = error.details;
      throw CommunityException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<CommunityPage> feed({Map<String, dynamic>? cursor}) async {
    final data = await _call('feed', {'cursor': ?cursor});
    return CommunityPage(
      (data['requests'] as List)
          .map(
            (item) => CommunityRequest.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      data['next_cursor'] == null
          ? null
          : Map<String, dynamic>.from(data['next_cursor'] as Map),
      DateTime.parse(data['server_now'] as String),
    );
  }

  @override
  Future<CommunityRequest?> get(String requestId) async {
    final data = await _call('get', {'request_id': requestId});
    return data['request'] == null
        ? null
        : CommunityRequest.fromJson(
            Map<String, dynamic>.from(data['request'] as Map),
          );
  }

  @override
  Future<CommunityReceipt> create(
    String operationId,
    String skill,
    String message,
  ) async {
    final data = await _call('create', {
      'client_operation_id': operationId,
      'skill': skill,
      'message': message,
    });
    return CommunityReceipt(
      data['request_id'] as String,
      data['state'] == 'active',
    );
  }

  @override
  Future<void> close(String operationId, String requestId) async {
    await _call('close', {
      'client_operation_id': operationId,
      'request_id': requestId,
    });
  }

  @override
  Future<MemberCapabilities> capabilities() async {
    _checkIdentity();
    final level = await LiveApi(client).capabilities();
    _checkIdentity();
    return level;
  }

  @override
  Future<Uint8List?> photo(CommunityRequest request) async {
    _checkIdentity();
    final path = request.author.avatarPath;
    if (path == null) return null;
    final photo = await client.storage.from('avatars').download(path);
    _checkIdentity();
    return photo;
  }
}
