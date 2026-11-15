import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'android_foreground_notifications.dart';
import 'native_push_envelope.dart';
export 'native_push_envelope.dart';

/// Identical compile-time configuration in the main and background isolates.
/// A null result permits Firebase to use the installed native configuration.
FirebaseOptions? firebaseOptionsFromDefines({
  String apiKey = const String.fromEnvironment('PAUL_FIREBASE_API_KEY'),
  String appId = const String.fromEnvironment('PAUL_FIREBASE_APP_ID'),
  String messagingSenderId = const String.fromEnvironment(
    'PAUL_FIREBASE_MESSAGING_SENDER_ID',
  ),
  String projectId = const String.fromEnvironment('PAUL_FIREBASE_PROJECT_ID'),
  String iosBundleId = const String.fromEnvironment(
    'PAUL_FIREBASE_IOS_BUNDLE_ID',
  ),
}) {
  final required = [apiKey, appId, messagingSenderId, projectId];
  if (required.every((value) => value.isEmpty) && iosBundleId.isEmpty) {
    return null;
  }
  if (required.any((value) => value.isEmpty)) {
    throw const FormatException(
      'Incomplete Firebase application configuration.',
    );
  }
  return FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
    iosBundleId: iosBundleId.isEmpty ? null : iosBundleId,
  );
}

@pragma('vm:entry-point')
Future<void> paulNativeMessageBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: firebaseOptionsFromDefines());
  }
  // The provider displays the fixed notification. No navigation, credentials,
  // private API calls or user data are handled by a background isolate.
  NativePushEnvelope.parse(message.data);
}

Future<void> initializeNativeMessaging({FirebaseOptions? options}) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: options ?? firebaseOptionsFromDefines(),
    );
  }
  FirebaseMessaging.onBackgroundMessage(paulNativeMessageBackgroundHandler);
  if (Platform.isIOS) {
    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
          alert: true,
          badge: true,
          sound: true,
        );
  }
}

enum NativePushPermission { notDetermined, denied, authorized, provisional }

abstract interface class ForegroundMessagingPort {
  Future<void> showForeground(NativePushEnvelope envelope);
  Future<void> clearForeground();
  Future<void> disposeForeground();
}

abstract interface class MessagingPort {
  bool get isApple;
  Stream<String> get tokenChanges;
  Stream<Map<String, dynamic>> get taps;
  Stream<Map<String, dynamic>> get foreground;
  Future<Map<String, dynamic>?> initialTap();
  Future<NativePushPermission> permission({bool request = false});
  Future<String?> apnsToken();
  Future<String?> token();
  Future<void> deleteToken();
}

class FirebaseMessagingPort implements MessagingPort, ForegroundMessagingPort {
  FirebaseMessagingPort([
    FirebaseMessaging? messaging,
    AndroidForegroundNotifications? local,
  ]) : _messaging = messaging ?? FirebaseMessaging.instance,
       _local =
           local ??
           (Platform.isAndroid ? AndroidForegroundNotifications() : null);
  final FirebaseMessaging _messaging;
  final AndroidForegroundNotifications? _local;
  @override
  bool get isApple => Platform.isIOS;
  @override
  Stream<String> get tokenChanges => _messaging.onRegistered;
  @override
  Stream<Map<String, dynamic>> get taps => mergeNativePushTaps(
    FirebaseMessaging.onMessageOpenedApp.map((message) => message.data),
    _local?.taps,
  );
  @override
  Stream<Map<String, dynamic>> get foreground =>
      FirebaseMessaging.onMessage.map((message) => message.data);
  @override
  Future<Map<String, dynamic>?> initialTap() async {
    // A local OS channel/icon failure must not swallow a valid FCM launch.
    try {
      final local = await _local?.initialTap();
      if (local != null) return local;
    } catch (_) {}
    return (await _messaging.getInitialMessage())?.data;
  }

  @override
  Future<void> showForeground(NativePushEnvelope envelope) async =>
      _local?.show(envelope);
  @override
  Future<void> clearForeground() async => _local?.clear();
  @override
  Future<void> disposeForeground() async => _local?.dispose();
  @override
  Future<NativePushPermission> permission({bool request = false}) async {
    final settings = request
        ? await _messaging.requestPermission()
        : await _messaging.getNotificationSettings();
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized => NativePushPermission.authorized,
      AuthorizationStatus.provisional => NativePushPermission.provisional,
      AuthorizationStatus.denied ||
      AuthorizationStatus.deniedPermanently => NativePushPermission.denied,
      AuthorizationStatus.notDetermined => NativePushPermission.notDetermined,
    };
  }

  @override
  Future<String?> apnsToken() => _messaging.getAPNSToken();
  @override
  Future<String?> token() async {
    // FCM 17 supplies an Installation ID through onRegistered, including when
    // already registered. Listen before register so a synchronous event is kept.
    final registered = Completer<String>();
    final subscription = _messaging.onRegistered.listen(
      (fid) {
        if (!registered.isCompleted) registered.complete(fid);
      },
      onError: (Object error, StackTrace stack) {
        if (!registered.isCompleted) registered.completeError(error, stack);
      },
    );
    try {
      final result = await Future.wait<Object?>([
        registered.future,
        _messaging.register(),
      ], eagerError: true).timeout(const Duration(seconds: 10));
      return result.first as String;
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<void> deleteToken() => _messaging.unregister();
}

Stream<Map<String, dynamic>> mergeNativePushTaps(
  Stream<Map<String, dynamic>> cloud,
  Stream<Map<String, dynamic>>? local,
) => Stream<Map<String, dynamic>>.multi((controller) {
  final cloudSubscription = cloud.listen(
    controller.add,
    onError: controller.addError,
  );
  final localSubscription = local?.listen(
    controller.add,
    onError: controller.addError,
  );
  controller.onCancel = () {
    unawaited(cloudSubscription.cancel());
    unawaited(localSubscription?.cancel());
  };
}, isBroadcast: true);
