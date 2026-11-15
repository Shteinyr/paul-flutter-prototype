import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/platform/notifications/android_foreground_notifications.dart';
import 'package:paul_demo/platform/notifications/native_messaging.dart';
import 'package:paul_demo/push/push_browser_types.dart';

const envelope = NativePushEnvelope(
  PushClick(
    '15000000-0000-4000-8000-000000000001',
    '15100000-0000-4000-8000-000000000001',
    '15200000-0000-4000-8000-000000000001',
  ),
  'message_created',
);

class AndroidPlugin extends Fake
    implements AndroidFlutterLocalNotificationsPlugin {
  final channels = <AndroidNotificationChannel>[];
  @override
  Future<void> createNotificationChannel(
    AndroidNotificationChannel channel,
  ) async => channels.add(channel);
}

class LocalPlugin extends Fake implements FlutterLocalNotificationsPlugin {
  final android = AndroidPlugin();
  final active = <ActiveNotification>[];
  int initialized = 0, cleared = 0;
  bool failShow = false;
  Completer<bool?>? initialization;
  InitializationSettings? settings;
  DidReceiveNotificationResponseCallback? response;
  NotificationAppLaunchDetails? launch;
  final shown =
      <
        ({
          int id,
          String? title,
          String? body,
          NotificationDetails? details,
          String? payload,
        })
      >[];
  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initialized++;
    this.settings = settings;
    response = onDidReceiveNotificationResponse;
    expect(onDidReceiveBackgroundNotificationResponse, isNull);
    return initialization == null ? true : initialization!.future;
  }

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => android as T;
  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async => launch;
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    if (failShow) throw StateError('OS unavailable');
    shown.add((
      id: id,
      title: title,
      body: body,
      details: notificationDetails,
      payload: payload,
    ));
    active.add(
      ActiveNotification(id: id, tag: notificationDetails?.android?.tag),
    );
  }

  @override
  Future<void> cancelAll() async {
    cleared++;
    active.clear();
  }

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => active;
}

NotificationResponse tap(String? payload) => NotificationResponse(
  notificationResponseType: NotificationResponseType.selectedNotification,
  payload: payload,
);

void main() {
  late LocalPlugin plugin;
  late AndroidForegroundNotifications notifications;
  setUp(() {
    plugin = LocalPlugin();
    notifications = AndroidForegroundNotifications(plugin: plugin);
  });
  tearDown(() => notifications.dispose());
  test(
    'Android channel initializes once without initializing iOS or requesting another permission',
    () async {
      await Future.wait([
        notifications.initialize(),
        notifications.initialize(),
      ]);
      expect(plugin.initialized, 1);
      expect(plugin.settings!.android!.defaultIcon, nativeNotificationIcon);
      expect(plugin.settings!.iOS, isNull);
      expect(plugin.android.channels.single.id, nativeNotificationChannelId);
      expect(plugin.android.channels.single.importance, Importance.high);
    },
  );
  test(
    'OS notification has fixed text and routing payload; each delivery has a stable ID and tag',
    () async {
      await Future.wait([
        notifications.show(envelope),
        notifications.show(envelope),
      ]);
      expect(plugin.shown, hasLength(1));
      final shown = plugin.shown.single;
      expect(shown.id, nativeNotificationId(envelope.click.deliveryId));
      expect(shown.title, 'Paul');
      expect(shown.body, 'New message');
      expect(shown.details!.android!.tag, envelope.click.deliveryId);
      expect(shown.details!.android!.onlyAlertOnce, isTrue);
      expect(shown.details!.android!.importance, Importance.high);
      expect(jsonDecode(shown.payload!), envelope.toData());
      final hiring = NativePushEnvelope(
        PushClick(
          envelope.click.recipientId,
          envelope.click.bindingId,
          '15200000-0000-4000-8000-000000000002',
        ),
        'community_created',
      );
      await notifications.show(hiring);
      expect(plugin.shown.last.body, 'New Hiring request');
      expect(plugin.shown.last.id, isNot(shown.id));
    },
  );
  test(
    'an active FCM notification is not duplicated locally; active numeric ID collisions cannot replace another tap',
    () async {
      plugin.active.add(
        ActiveNotification(id: 0, tag: envelope.click.deliveryId),
      );
      await notifications.show(envelope);
      expect(plugin.shown, isEmpty);
      final next = NativePushEnvelope(
        PushClick(
          envelope.click.recipientId,
          envelope.click.bindingId,
          '15200000-0000-4000-8000-000000000003',
        ),
        'community_created',
      );
      final candidate = nativeNotificationId(next.click.deliveryId);
      plugin.active.add(
        ActiveNotification(id: candidate, tag: 'other-delivery'),
      );
      await notifications.show(next);
      expect(
        plugin.shown.single.id,
        candidate == 0x7fffffff ? 1 : candidate + 1,
      );
      expect(jsonDecode(plugin.shown.single.payload!), next.toData());
    },
  );
  test(
    'cold local launch is delivered once through the validated routing envelope',
    () async {
      plugin.launch = NotificationAppLaunchDetails(
        true,
        notificationResponse: tap(
          jsonEncode({
            ...envelope.toData(),
            'title': 'private name',
            'body': 'private message',
          }),
        ),
      );
      expect(await notifications.initialTap(), envelope.toData());
      expect(await notifications.initialTap(), isNull);
    },
  );
  test(
    'local hot clicks and FCM clicks merge; cancellation detaches both streams',
    () async {
      final cloud = StreamController<Map<String, dynamic>>.broadcast();
      final events = <Map<String, dynamic>>[];
      final subscription = mergeNativePushTaps(
        cloud.stream,
        notifications.taps,
      ).listen(events.add);
      await notifications.initialize();
      plugin.response!(tap(jsonEncode(envelope.toData())));
      cloud.add({...envelope.toData(), 'kind': 'community_created'});
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events.map((event) => event['kind']).toSet(), {
        'message_created',
        'community_created',
      });
      await subscription.cancel();
      expect(cloud.hasListener, isFalse);
      await cloud.close();
    },
  );
  test(
    'malformed, oversized and unsupported local payloads never route',
    () async {
      final events = <Map<String, dynamic>>[];
      final subscription = notifications.taps.listen(events.add);
      await notifications.initialize();
      for (final payload in [
        null,
        '{',
        '[]',
        'x' * 2049,
        jsonEncode({...envelope.toData(), 'kind': 'unknown'}),
        jsonEncode({...envelope.toData(), 'binding_id': 'invalid'}),
      ]) {
        plugin.response!(tap(payload));
      }
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await subscription.cancel();
    },
  );
  test(
    'failed OS display can retry and logout clears displayed notifications',
    () async {
      plugin.failShow = true;
      await expectLater(notifications.show(envelope), throwsStateError);
      plugin.failShow = false;
      await notifications.show(envelope);
      expect(plugin.shown, hasLength(1));
      await notifications.clear();
      expect(plugin.cleared, 1);
      await notifications.show(envelope);
      expect(plugin.shown, hasLength(2));
    },
  );
  test(
    'dispose during initialization prevents late local display and tap delivery',
    () async {
      plugin.initialization = Completer<bool?>();
      final showing = notifications.show(envelope);
      await Future<void>.delayed(Duration.zero);
      await notifications.dispose();
      plugin.initialization!.complete(true);
      await showing;
      plugin.response!(tap(jsonEncode(envelope.toData())));
      expect(plugin.shown, isEmpty);
    },
  );
  test(
    'Firebase options use one explicit configuration for foreground and background; partial values fail closed',
    () {
      expect(
        firebaseOptionsFromDefines(
          apiKey: '',
          appId: '',
          messagingSenderId: '',
          projectId: '',
          iosBundleId: '',
        ),
        isNull,
      );
      expect(
        () => firebaseOptionsFromDefines(
          apiKey: 'test',
          appId: '',
          messagingSenderId: '',
          projectId: '',
          iosBundleId: '',
        ),
        throwsFormatException,
      );
      final options = firebaseOptionsFromDefines(
        apiKey: 'test-key',
        appId: 'test-app',
        messagingSenderId: '123',
        projectId: 'test-project',
        iosBundleId: 'app.paul',
      );
      expect(options!.apiKey, 'test-key');
      expect(options.appId, 'test-app');
      expect(options.messagingSenderId, '123');
      expect(options.projectId, 'test-project');
      expect(options.iosBundleId, 'app.paul');
    },
  );
  test(
    'Firebase compile-time options retain build values for the background entry point',
    () {
      const key = String.fromEnvironment('PAUL_FIREBASE_API_KEY');
      final options = firebaseOptionsFromDefines();
      if (key.isEmpty) {
        expect(options, isNull);
      } else {
        expect(options!.apiKey, key);
        expect(
          options.appId,
          const String.fromEnvironment('PAUL_FIREBASE_APP_ID'),
        );
        expect(
          options.messagingSenderId,
          const String.fromEnvironment('PAUL_FIREBASE_MESSAGING_SENDER_ID'),
        );
        expect(
          options.projectId,
          const String.fromEnvironment('PAUL_FIREBASE_PROJECT_ID'),
        );
      }
    },
  );
}
