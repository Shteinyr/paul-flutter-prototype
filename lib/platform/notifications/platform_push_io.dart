import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../push/push_api.dart';
import '../storage/native_session_storage.dart';
import 'native_messaging.dart';
import 'native_push_api.dart';
import 'native_push_controller.dart';
import 'native_push_store.dart';
import 'platform_push_types.dart';

Future<PlatformPushRuntime?> createPlatformPushRuntime(
  SupabaseClient client,
) async {
  if (!Platform.isIOS && !Platform.isAndroid) return null;
  try {
    await initializeNativeMessaging();
    return _NativePushRuntime(
      client,
      NativePushController(
        messaging: FirebaseMessagingPort(),
        store: SqliteNativePushStore(NativeSessionStorage.current.database),
      ),
    );
  } catch (_) {
    // Unconfigured development builds can run without provider credentials.
    // A delivery build must supply and verify its Firebase/APNs configuration.
    return null;
  }
}

class _NativePushRuntime implements PlatformPushRuntime {
  _NativePushRuntime(this.client, this.controller) {
    _subscription = controller.routes.listen((route) {
      final user = _user, session = _session;
      if (!_disposed &&
          user != null &&
          session != null &&
          client.auth.currentUser?.id == user &&
          pushSessionId(client) == session) {
        _routes.add(PlatformPushNavigation(user, session, route));
      }
    });
  }
  final SupabaseClient client;
  final NativePushController controller;
  final _routes = StreamController<PlatformPushNavigation>.broadcast();
  late final StreamSubscription<PushRoute> _subscription;
  String? _user, _session;
  bool _disposed = false;
  @override
  Stream<PlatformPushNavigation> get routes => _routes.stream;

  @override
  Future<void> bind({
    required String? userId,
    required String? sessionId,
    required bool admitted,
  }) async {
    if (_disposed) return;
    if (admitted && userId == _user && sessionId == _session) {
      await controller.refresh();
      return;
    }
    _user = admitted ? userId : null;
    _session = admitted ? sessionId : null;
    await controller.setIdentity(
      userId: userId,
      sessionId: sessionId,
      admitted: admitted,
      repository: admitted && userId != null && sessionId != null
          ? SupabaseNativePushApi(client, userId, sessionId)
          : null,
    );
    if (!_disposed &&
        admitted &&
        _user == userId &&
        _session == sessionId &&
        controller.permission == NativePushPermission.notDetermined) {
      await controller.requestPermission();
    }
  }

  @override
  Future<void> refresh() => controller.refresh();

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _subscription.cancel();
    await controller.dispose();
    await _routes.close();
  }
}
