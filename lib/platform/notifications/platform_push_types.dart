import '../../push/push_api.dart';

class PlatformPushNavigation {
  const PlatformPushNavigation(this.userId, this.sessionId, this.route);
  final String userId, sessionId;
  final PushRoute route;
}

abstract interface class PlatformPushRuntime {
  Stream<PlatformPushNavigation> get routes;
  Future<void> bind({
    required String? userId,
    required String? sessionId,
    required bool admitted,
  });
  Future<void> refresh();
  Future<void> dispose();
}
