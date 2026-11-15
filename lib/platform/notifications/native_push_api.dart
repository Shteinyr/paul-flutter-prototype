import 'package:supabase_flutter/supabase_flutter.dart';

import '../../push/push_api.dart';
import '../../push/push_browser_types.dart';

abstract interface class NativePushRepository {
  Future<String> subscribe(String bindingId, String token, String platform);
  Future<void> unsubscribe(String bindingId);
  Future<PushRoute> resolve(PushClick click);
}

class NativePushRequestException implements Exception {
  const NativePushRequestException(this.code);
  final String code;
  @override
  String toString() => 'Notification request could not be completed.';
}

class SupabaseNativePushApi implements NativePushRepository {
  const SupabaseNativePushApi(this.client, this.userId, this.sessionId);
  final SupabaseClient client;
  final String userId, sessionId;
  void _check() {
    if (client.auth.currentUser?.id != userId ||
        pushSessionId(client) != sessionId) {
      throw const NativePushRequestException('session_changed');
    }
  }

  Future<Map<String, dynamic>> _call(
    String action,
    Map<String, dynamic> fields,
  ) async {
    _check();
    final token = client.auth.currentSession?.accessToken;
    if (token == null) {
      throw const NativePushRequestException('sign_in_required');
    }
    try {
      final result = await client.functions
          .invoke(
            'native-push',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': action, ...fields},
          )
          .timeout(const Duration(seconds: 20));
      _check();
      return Map<String, dynamic>.from(result.data as Map);
    } on FunctionException catch (error) {
      _check();
      throw NativePushRequestException(
        error.details is Map
            ? (error.details as Map)['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<String> subscribe(
    String bindingId,
    String token,
    String platform,
  ) async {
    final data = await _call('subscribe', {
      'binding_id': bindingId,
      'token': token,
      'platform': platform,
    });
    final canonical = data['binding_id'];
    if (data['recipient_user_id'] != userId ||
        data['session_id'] != sessionId ||
        data['enabled'] != true ||
        canonical is! String ||
        !pushUuid.hasMatch(canonical)) {
      throw const NativePushRequestException('invalid_binding');
    }
    return canonical;
  }

  @override
  Future<void> unsubscribe(String bindingId) async {
    await _call('unsubscribe', {'binding_id': bindingId});
  }

  @override
  Future<PushRoute> resolve(PushClick click) async {
    if (click.recipientId != userId) {
      throw const NativePushRequestException('push_forbidden');
    }
    final data = await _call('resolve', {
      'delivery_id': click.deliveryId,
      'binding_id': click.bindingId,
    });
    final kind = data['kind'];
    if (kind == 'community') {
      final id = data['request_id'], state = data['state'];
      if (id is! String ||
          !pushUuid.hasMatch(id) ||
          (state != 'active' && state != 'unavailable')) {
        throw const NativePushRequestException('push_forbidden');
      }
      return PushRoute.community(id, state as String);
    }
    final id = data['conversation_id'], managed = data['managed_profile_id'];
    if ((kind != 'chat' && kind != 'operator') ||
        id is! String ||
        !pushUuid.hasMatch(id) ||
        (kind == 'operator' &&
            (managed is! String || !pushUuid.hasMatch(managed)))) {
      throw const NativePushRequestException('push_forbidden');
    }
    return PushRoute(kind as String, id, managed as String?);
  }
}
