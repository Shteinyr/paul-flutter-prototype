import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'native_push_envelope.dart';

const nativeNotificationChannelId = 'paul_activity';
const nativeNotificationIcon = 'ic_stat_paul';

int nativeNotificationId(String deliveryId) {
  final bytes = sha256.convert(utf8.encode(deliveryId)).bytes;
  final value =
      ((bytes[0] & 0x7f) << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  return value == 0 ? 1 : value;
}

/// Android OS notifications only; permission belongs to FirebaseMessaging.
/// Call show only after the controller verifies the current account binding.
class AndroidForegroundNotifications {
  AndroidForegroundNotifications({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  final _taps = StreamController<Map<String, dynamic>>.broadcast();
  final _shown = <String>{};
  Future<void>? _initializing;
  Map<String, dynamic>? _launch;
  bool _launchConsumed = false, _disposed = false;
  Future<void> _work = Future.value();
  Stream<Map<String, dynamic>> get taps => _taps.stream;

  static Map<String, dynamic>? parsePayload(String? payload) {
    if (payload == null || payload.length > 2048) return null;
    try {
      final value = jsonDecode(payload);
      if (value is! Map<String, dynamic>) return null;
      return NativePushEnvelope.parse(value)?.toData();
    } catch (_) {
      return null;
    }
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (_disposed) return;
    final initialized = await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(nativeNotificationIcon),
      ),
      onDidReceiveNotificationResponse: (response) {
        final data = parsePayload(response.payload);
        if (!_disposed && data != null) _taps.add(data);
      },
    );
    if (initialized != true) {
      throw StateError('Android notifications unavailable.');
    }
    if (_disposed) return;
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            nativeNotificationChannelId,
            'Paul',
            description: 'Messages and Hiring requests',
            importance: Importance.high,
          ),
        );
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (!_disposed && details?.didNotificationLaunchApp == true) {
      _launch = parsePayload(details?.notificationResponse?.payload);
    }
  }

  Future<Map<String, dynamic>?> initialTap() async {
    await initialize();
    if (_disposed || _launchConsumed) return null;
    _launchConsumed = true;
    return _launch;
  }

  Future<void> _serialize(Future<void> Function() action) {
    final work = _work.then((_) => action());
    _work = work.catchError((Object _) {});
    return work;
  }

  Future<void> show(NativePushEnvelope envelope) =>
      _serialize(() => _show(envelope));
  Future<void> _show(NativePushEnvelope envelope) async {
    await initialize();
    if (_disposed) return;
    final key = '${envelope.click.bindingId}:${envelope.click.deliveryId}';
    if (_shown.contains(key)) return;
    if (_shown.length >= 256) _shown.remove(_shown.first);
    _shown.add(key);
    try {
      final active = await _plugin.getActiveNotifications();
      if (_disposed) return;
      // Preserve an already visible local or FCM notification for this
      // delivery, including after process restart. Its original tap is valid.
      if (active.any((item) => item.tag == envelope.click.deliveryId)) return;
      var id = nativeNotificationId(envelope.click.deliveryId);
      while (active.any((item) => item.id == id)) {
        id = id == 0x7fffffff ? 1 : id + 1;
      }
      await _plugin.show(
        // The plugin uses id as PendingIntent's requestCode. Distinct active
        // deliveries require distinct IDs as well as their stable UUID tags.
        id: id,
        title: 'Paul',
        body: envelope.kind == 'message_created'
            ? 'New message'
            : 'New Hiring request',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            nativeNotificationChannelId,
            'Paul',
            channelDescription: 'Messages and Hiring requests',
            icon: nativeNotificationIcon,
            importance: Importance.high,
            priority: Priority.high,
            onlyAlertOnce: true,
            tag: envelope.click.deliveryId,
          ),
        ),
        payload: jsonEncode(envelope.toData()),
      );
    } catch (_) {
      _shown.remove(key);
      rethrow;
    }
  }

  Future<void> clear() => _serialize(_clear);
  Future<void> _clear() async {
    await initialize();
    if (_disposed) return;
    _shown.clear();
    // Paul has one message/Hiring notification channel. Remove old account
    // banners at logout along with its server and device registrations.
    await _plugin.cancelAll();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _taps.close();
  }
}
