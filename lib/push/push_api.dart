import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'push_browser_types.dart';

String? pushSessionId(SupabaseClient client) {
  final token = client.auth.currentSession?.accessToken;
  if (token == null) return null;
  try {
    final data = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
    );
    final id = data['session_id'];
    return id is String && pushUuid.hasMatch(id) ? id : null;
  } catch (_) {
    return null;
  }
}

class PushException implements Exception {
  const PushException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'sign_in_required' ||
    'session_revoked' => 'Sign in again to enable notifications.',
    'push_forbidden' ||
    'membership_required' => 'Notifications are unavailable for this account.',
    'binding_conflict' =>
      'Notifications belong to another sign-in. Disable them there, then retry.',
    'rate_limited' => 'Too many attempts. Wait a minute, then retry.',
    _ => 'Could not update notifications. Check your connection and retry.',
  };
}

class PushConfiguration {
  const PushConfiguration(this.enabled, this.publicKey);
  final bool enabled;
  final String? publicKey;
}

class PushRoute {
  const PushRoute(this.kind, this.conversationId, this.managedProfileId)
    : requestId = null,
      requestState = null;
  const PushRoute.community(String id, String state)
    : kind = 'community',
      conversationId = '',
      managedProfileId = null,
      requestId = id,
      requestState = state;
  final String kind;
  final String conversationId;
  final String? managedProfileId;
  final String? requestId;
  final String? requestState;
}

abstract interface class PushRepository {
  String get userId;
  String get sessionId;
  bool get current;
  Future<PushConfiguration> config();
  Future<String> subscribe(PreparedPush push);
  Future<bool> status(String bindingId);
  Future<void> unsubscribe(String bindingId);
  Future<PushRoute> resolve(PushClick click);
}

class SupabasePushApi implements PushRepository {
  const SupabasePushApi(this.client, this.userId, this.sessionId);
  final SupabaseClient client;
  @override
  final String userId;
  @override
  final String sessionId;
  @override
  bool get current =>
      client.auth.currentUser?.id == userId &&
      pushSessionId(client) == sessionId;
  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    if (!current) throw const PushException('sign_in_required');
    final token = client.auth.currentSession!.accessToken;
    try {
      final response = await client.functions
          .invoke(
            'push',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': action, ...fields},
          )
          .timeout(const Duration(seconds: 20));
      if (!current) throw const PushException('sign_in_required');
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      final details = error.details;
      throw PushException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<PushConfiguration> config() async {
    final data = await _call('config');
    if (data['version'] != 1) throw const PushException('server_unavailable');
    return PushConfiguration(
      data['enabled'] == true,
      data['vapid_public_key'] as String?,
    );
  }

  @override
  Future<String> subscribe(PreparedPush push) async {
    final data = await _call('subscribe', {
      'binding_id': push.bindingId,
      'subscription': push.subscription,
    });
    final binding = data['binding_id'];
    if (data['recipient_user_id'] != userId ||
        data['enabled'] != true ||
        binding is! String ||
        !pushUuid.hasMatch(binding)) {
      throw const PushException('server_unavailable');
    }
    return binding;
  }

  @override
  Future<bool> status(String bindingId) async {
    final data = await _call('status', {'binding_id': bindingId});
    if (data['recipient_user_id'] != userId ||
        data['binding_id'] != bindingId) {
      throw const PushException('push_forbidden');
    }
    return data['enabled'] == true;
  }

  @override
  Future<void> unsubscribe(String bindingId) async {
    await _call('unsubscribe', {'binding_id': bindingId});
  }

  @override
  Future<PushRoute> resolve(PushClick click) async {
    if (click.recipientId != userId) {
      throw const PushException('push_forbidden');
    }
    final data = await _call('resolve', {
      'delivery_id': click.deliveryId,
      'binding_id': click.bindingId,
    });
    final kind = data['kind'];
    final conversation = data['conversation_id'];
    final managed = data['managed_profile_id'];
    if (kind == 'community') {
      final request = data['request_id'];
      final state = data['state'];
      if (request is! String ||
          !pushUuid.hasMatch(request) ||
          (state != 'active' && state != 'unavailable')) {
        throw const PushException('push_forbidden');
      }
      return PushRoute.community(request, state as String);
    }
    if ((kind != 'chat' && kind != 'operator') ||
        conversation is! String ||
        !pushUuid.hasMatch(conversation) ||
        (kind == 'operator' &&
            (managed is! String || !pushUuid.hasMatch(managed)))) {
      throw const PushException('push_forbidden');
    }
    return PushRoute(kind as String, conversation, managed as String?);
  }
}
