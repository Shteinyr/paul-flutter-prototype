import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../../push/push_browser_types.dart';

@pragma('vm:entry-point')
Future<void> paulNativeMessageBackgroundHandler(RemoteMessage message) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  // The provider displays the fixed notification. No navigation, credentials,
  // private API calls or user data are handled by a background isolate.
  NativePushEnvelope.parse(message.data);
}

Future<void> initializeNativeMessaging({FirebaseOptions? options}) async {
  if (Firebase.apps.isEmpty) await Firebase.initializeApp(options: options);
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

class NativePushEnvelope {
  const NativePushEnvelope(this.click, this.kind);
  final PushClick click;
  final String kind;
  static NativePushEnvelope? parse(Map<String, dynamic> data) {
    final version = data['version'];
    final kind = data['kind'];
    if ((version != 1 && version != '1') ||
        (kind != 'message_created' && kind != 'community_created')) {
      return null;
    }
    final click = PushClick.parse({...data, 'version': 1});
    return click == null ? null : NativePushEnvelope(click, kind as String);
  }
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

class FirebaseMessagingPort implements MessagingPort {
  FirebaseMessagingPort([FirebaseMessaging? messaging])
    : _messaging = messaging ?? FirebaseMessaging.instance;
  final FirebaseMessaging _messaging;
  @override
  bool get isApple => Platform.isIOS;
  @override
  Stream<String> get tokenChanges => _messaging.onRegistered;
  @override
  Stream<Map<String, dynamic>> get taps =>
      FirebaseMessaging.onMessageOpenedApp.map((message) => message.data);
  @override
  Stream<Map<String, dynamic>> get foreground =>
      FirebaseMessaging.onMessage.map((message) => message.data);
  @override
  Future<Map<String, dynamic>?> initialTap() async =>
      (await _messaging.getInitialMessage())?.data;
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
