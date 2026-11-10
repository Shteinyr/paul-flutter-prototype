import 'dart:async';

final pushUuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

class PushClick {
  const PushClick(this.recipientId, this.bindingId, this.deliveryId);
  final String recipientId;
  final String bindingId;
  final String deliveryId;
  static PushClick? parse(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    final ids = [
      'recipient_user_id',
      'binding_id',
      'delivery_id',
    ].map((key) => value[key]).toList();
    if (ids.any((id) => id is! String || !pushUuid.hasMatch(id))) return null;
    return PushClick(ids[0] as String, ids[1] as String, ids[2] as String);
  }
}

class BrowserPushState {
  const BrowserPushState({
    required this.supported,
    required this.permission,
    this.bindingId,
    this.active = false,
    this.storageFull = false,
  });
  final bool supported;
  final String permission;
  final String? bindingId;
  final bool active;
  final bool storageFull;
}

class PreparedPush {
  const PreparedPush(this.bindingId, this.subscription);
  final String bindingId;
  final Map<String, dynamic> subscription;
}

abstract interface class PushBrowser {
  Stream<PushClick> get clicks;
  PushClick? takeClick();
  Future<void> identity(String? userId, String? sessionId);
  Future<BrowserPushState> inspect();
  Future<String> permission();
  Future<PreparedPush> prepare(String userId, String publicKey);
  Future<void> commit(String userId, String proposedId, String canonicalId);
  Future<String?> clear(String userId, String sessionId);
  void dispose();
}
