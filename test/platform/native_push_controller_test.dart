import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/platform/notifications/native_messaging.dart';
import 'package:paul_demo/platform/notifications/native_push_api.dart';
import 'package:paul_demo/platform/notifications/native_push_controller.dart';
import 'package:paul_demo/platform/notifications/native_push_store.dart';
import 'package:paul_demo/push/push_api.dart';
import 'package:paul_demo/push/push_browser_types.dart';

const actor = '15000000-0000-4000-8000-000000000001';
const other = '15000000-0000-4000-8000-000000000002';
const session = '15000000-0000-4000-8000-000000000003';
const bindingId = '15000000-0000-4000-8000-000000000004';
const deliveryId = '15000000-0000-4000-8000-000000000005';
Map<String, dynamic> envelope({
  String user = actor,
  String binding = bindingId,
  String kind = 'message_created',
}) => {
  'version': '1',
  'recipient_user_id': user,
  'binding_id': binding,
  'delivery_id': deliveryId,
  'kind': kind,
};

class Messaging extends Fake implements MessagingPort, ForegroundMessagingPort {
  @override
  bool isApple = false;
  final tokens = StreamController<String>.broadcast(sync: true);
  final clicks = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final active = StreamController<Map<String, dynamic>>.broadcast(sync: true);
  NativePushPermission authorization = NativePushPermission.authorized;
  String? apns = 'apple-token';
  String? currentToken = 'device-token-12345678901234567890';
  Map<String, dynamic>? initial;
  Completer<Map<String, dynamic>?>? initialGate;
  int prompts = 0, deletes = 0, reads = 0;
  int failedDeletes = 0, foregroundClears = 0, foregroundDisposals = 0;
  final shown = <NativePushEnvelope>[];
  @override
  Future<void> showForeground(NativePushEnvelope envelope) async =>
      shown.add(envelope);
  @override
  Future<void> clearForeground() async {
    foregroundClears++;
  }

  @override
  Future<void> disposeForeground() async {
    foregroundDisposals++;
  }

  @override
  Stream<String> get tokenChanges => tokens.stream;
  @override
  Stream<Map<String, dynamic>> get taps => clicks.stream;
  @override
  Stream<Map<String, dynamic>> get foreground => active.stream;
  @override
  Future<Map<String, dynamic>?> initialTap() async =>
      initialGate == null ? initial : initialGate!.future;
  @override
  Future<NativePushPermission> permission({bool request = false}) async {
    if (request) prompts++;
    return authorization;
  }

  @override
  Future<String?> apnsToken() async => apns;
  @override
  Future<String?> token() async {
    reads++;
    return currentToken;
  }

  @override
  Future<void> deleteToken() async {
    deletes++;
    if (failedDeletes > 0) {
      failedDeletes--;
      throw StateError('offline unregistration');
    }
  }

  Future<void> close() async {
    await tokens.close();
    await clicks.close();
    await active.close();
  }
}

class Bindings implements NativePushStore, NativePushRetirementStore {
  final values = <(String, String), NativePushBinding>{};
  bool retiring = false;
  @override
  Future<bool> retirementPending() async => retiring;
  @override
  Future<void> setRetirementPending(bool pending) async {
    retiring = pending;
  }

  @override
  Future<NativePushBinding?> read(String userId, String sessionId) async =>
      values[(userId, sessionId)];
  @override
  Future<void> write(NativePushBinding binding) async =>
      values[(binding.userId, binding.sessionId)] = binding;
  @override
  Future<void> remove(String userId, String sessionId) async {
    values.remove((userId, sessionId));
  }
}

class Repository implements NativePushRepository {
  final registrations = <(String, String, String)>[];
  final removals = <String>[];
  final resolutions = <PushClick>[];
  Completer<String>? registering;
  Completer<PushRoute>? resolving;
  Completer<void>? resolveReached;
  bool fail = false;
  @override
  Future<String> subscribe(String id, String token, String platform) async {
    registrations.add((id, token, platform));
    if (fail) {
      throw const NativePushRequestException('session_admission_required');
    }
    return registering == null ? id : registering!.future;
  }

  @override
  Future<void> unsubscribe(String id) async => removals.add(id);
  @override
  Future<PushRoute> resolve(PushClick click) async {
    resolutions.add(click);
    resolveReached?.complete();
    return resolving == null
        ? const PushRoute('chat', other, null)
        : resolving!.future;
  }
}

void main() {
  late Messaging messaging;
  late Bindings bindings;
  late Repository repository;
  late NativePushController controller;
  setUp(() {
    messaging = Messaging();
    bindings = Bindings();
    repository = Repository();
    controller = NativePushController(messaging: messaging, store: bindings);
  });
  tearDown(() async {
    await controller.dispose();
    await messaging.close();
  });
  Future<void> admit() => controller.setIdentity(
    userId: actor,
    sessionId: session,
    admitted: true,
    repository: repository,
  );

  test(
    'unadmitted Auth cannot register, resolve or prompt permission',
    () async {
      await controller.setIdentity(
        userId: actor,
        sessionId: session,
        admitted: false,
      );
      await controller.requestPermission();
      messaging.tokens.add('rotated-token');
      messaging.clicks.add(envelope());
      await controller.settled;
      expect(repository.registrations, isEmpty);
      expect(repository.resolutions, isEmpty);
      expect(messaging.prompts, 0);
      expect(messaging.reads, 0);
    },
  );
  test(
    'persisted proposed binding survives rejected registration and is retried unchanged',
    () async {
      repository.fail = true;
      await admit();
      final original = repository.registrations.single.$1;
      expect((await bindings.read(actor, session))!.bindingId, original);
      expect(controller.enabled, isFalse);
      await controller.dispose();
      repository.fail = false;
      controller = NativePushController(messaging: messaging, store: bindings);
      await admit();
      expect(repository.registrations.last.$1, original);
      expect(controller.enabled, isTrue);
    },
  );
  test(
    'token rotation retains binding and updates only the device capability digest',
    () async {
      await admit();
      final before = (await bindings.read(actor, session))!;
      messaging.tokens.add('new-device-token-1234567890123456');
      await controller.settled;
      final after = (await bindings.read(actor, session))!;
      expect(after.bindingId, before.bindingId);
      expect(after.tokenDigest, isNot(before.tokenDigest));
      expect(
        repository.registrations.last.$2,
        'new-device-token-1234567890123456',
      );
    },
  );
  test(
    'iOS waits for APNs readiness and resume registers without another permission prompt',
    () async {
      messaging.isApple = true;
      messaging.apns = null;
      await admit();
      expect(controller.waitingForApns, isTrue);
      expect(repository.registrations, isEmpty);
      messaging.apns = 'ready';
      await controller.refresh();
      expect(repository.registrations.single.$3, 'ios');
      expect(controller.enabled, isTrue);
      expect(messaging.prompts, 0);
    },
  );
  test('only an explicit permission request invokes the OS prompt', () async {
    messaging.authorization = NativePushPermission.notDetermined;
    await admit();
    expect(messaging.prompts, 0);
    expect(controller.enabled, isFalse);
    messaging.authorization = NativePushPermission.authorized;
    await controller.requestPermission();
    expect(messaging.prompts, 1);
    expect(controller.enabled, isTrue);
  });
  test(
    'withdrawn permission disables the exact binding and retires the token',
    () async {
      await admit();
      final id = repository.registrations.single.$1;
      messaging.authorization = NativePushPermission.denied;
      await controller.refresh();
      expect(repository.removals, [id]);
      expect(messaging.deletes, 1);
      expect(bindings.values, isEmpty);
      expect(controller.enabled, isFalse);
    },
  );
  test(
    'logout waits for an in-flight registration then removes its original binding',
    () async {
      repository.registering = Completer<String>();
      final admitting = admit();
      while (repository.registrations.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final id = repository.registrations.single.$1;
      final logout = controller.setIdentity(
        userId: null,
        sessionId: null,
        admitted: false,
      );
      repository.registering!.complete(id);
      await admitting;
      await logout;
      expect(repository.removals, [id]);
      expect(bindings.values, isEmpty);
      expect(controller.enabled, isFalse);
    },
  );
  test(
    'tap is resolved by the server and repeated delivery does not navigate twice',
    () async {
      await admit();
      final routes = <PushRoute>[];
      final sub = controller.routes.listen(routes.add);
      final data = envelope(binding: repository.registrations.single.$1);
      messaging.clicks.add(data);
      await controller.settled;
      await Future<void>.delayed(Duration.zero);
      messaging.clicks.add(data);
      await controller.settled;
      expect(repository.resolutions, hasLength(1));
      expect(routes, hasLength(1));
      expect(routes.single.conversationId, other);
      await sub.cancel();
    },
  );
  test('another recipient or binding cannot reach server resolution', () async {
    await admit();
    messaging.clicks.add(envelope(user: other));
    await controller.settled;
    messaging.clicks.add(envelope());
    await controller.settled;
    expect(repository.resolutions, isEmpty);
  });
  test('account switch while resolving a tap discards the old route', () async {
    await admit();
    repository.resolving = Completer<PushRoute>();
    repository.resolveReached = Completer<void>();
    final routes = <PushRoute>[];
    final sub = controller.routes.listen(routes.add);
    messaging.clicks.add(envelope(binding: repository.registrations.single.$1));
    await repository.resolveReached!.future;
    final next = Repository();
    final switching = controller.setIdentity(
      userId: other,
      sessionId: deliveryId,
      admitted: true,
      repository: next,
    );
    repository.resolving!.complete(const PushRoute('chat', other, null));
    await switching;
    expect(routes, isEmpty);
    expect(repository.removals, hasLength(1));
    expect(next.registrations, hasLength(1));
    await sub.cancel();
  });
  test(
    'cold-start tap waits for the saved admitted identity and uses its binding',
    () async {
      await controller.dispose();
      await bindings.write(
        const NativePushBinding(actor, session, bindingId, 'digest'),
      );
      messaging.initial = envelope();
      controller = NativePushController(messaging: messaging, store: bindings);
      final routes = <PushRoute>[];
      final sub = controller.routes.listen(routes.add);
      await admit();
      await Future<void>.delayed(Duration.zero);
      expect(repository.resolutions, hasLength(1));
      expect(routes, hasLength(1));
      await sub.cancel();
    },
  );
  test('late initial notification after dispose has no side effects', () async {
    await controller.dispose();
    messaging.initialGate = Completer<Map<String, dynamic>?>();
    controller = NativePushController(messaging: messaging, store: bindings);
    await controller.dispose();
    messaging.initialGate!.complete(envelope());
    await Future<void>.delayed(Duration.zero);
    expect(repository.registrations, isEmpty);
    expect(repository.resolutions, isEmpty);
  });
  test(
    'payload parser rejects unknown event types and ignores notification content',
    () {
      expect(
        NativePushEnvelope.parse(envelope(kind: 'unapproved_event')),
        isNull,
      );
      expect(
        NativePushEnvelope.parse({
          ...envelope(),
          'recipient_user_id': 'not-a-uuid',
        }),
        isNull,
      );
      final parsed = NativePushEnvelope.parse({
        ...envelope(),
        'body': 'must not be used',
        'title': 'untrusted',
      });
      expect(parsed!.kind, 'message_created');
      expect(parsed.click.deliveryId, deliveryId);
    },
  );
  test(
    'Android foreground display requires admitted current owner and binding; iOS is not duplicated',
    () async {
      messaging.active.add(envelope());
      await controller.settled;
      expect(messaging.shown, isEmpty);
      await admit();
      messaging.active.add(envelope(user: other));
      messaging.active.add(envelope(binding: deliveryId));
      await controller.settled;
      expect(messaging.shown, isEmpty);
      messaging.active.add(
        envelope(binding: repository.registrations.single.$1),
      );
      await controller.settled;
      expect(messaging.shown.single.kind, 'message_created');
      messaging.isApple = true;
      messaging.active.add(envelope(kind: 'community_created'));
      await controller.settled;
      expect(messaging.shown, hasLength(1));
    },
  );
  test(
    'cold unadmitted startup retires device and ignores late registration events',
    () async {
      await controller.setIdentity(
        userId: null,
        sessionId: null,
        admitted: false,
      );
      expect(messaging.deletes, 1);
      expect(messaging.foregroundClears, 1);
      messaging.tokens.add('late-fid-installation-id');
      messaging.active.add(envelope());
      await controller.settled;
      expect(repository.registrations, isEmpty);
      expect(messaging.shown, isEmpty);
      expect(messaging.prompts, 0);
    },
  );
  test(
    'failed cold unregistration survives restart and blocks new registration until acknowledged',
    () async {
      messaging.failedDeletes = 3;
      await controller.setIdentity(
        userId: actor,
        sessionId: session,
        admitted: false,
      );
      expect(bindings.retiring, isTrue);
      await controller.dispose();
      controller = NativePushController(messaging: messaging, store: bindings);
      await controller.setIdentity(
        userId: null,
        sessionId: null,
        admitted: false,
      );
      await admit();
      expect(repository.registrations, isEmpty);
      expect(bindings.retiring, isTrue);
      await controller.refresh();
      expect(bindings.retiring, isFalse);
      expect(repository.registrations, hasLength(1));
      expect(messaging.deletes, 4);
    },
  );
  test(
    'signed-out resume retries pending retirement without registering or prompting',
    () async {
      messaging.failedDeletes = 1;
      await controller.setIdentity(
        userId: null,
        sessionId: null,
        admitted: false,
      );
      expect(bindings.retiring, isTrue);
      await controller.refresh();
      expect(bindings.retiring, isFalse);
      expect(messaging.deletes, 2);
      expect(repository.registrations, isEmpty);
      expect(messaging.prompts, 0);
    },
  );
  test(
    'a later hot click wins over delayed cold notification launch',
    () async {
      await controller.dispose();
      messaging.initialGate = Completer<Map<String, dynamic>?>();
      controller = NativePushController(messaging: messaging, store: bindings);
      await admit();
      final routes = <PushRoute>[];
      final sub = controller.routes.listen(routes.add);
      final data = envelope(binding: repository.registrations.single.$1);
      messaging.clicks.add(data);
      await controller.settled;
      await Future<void>.delayed(Duration.zero);
      messaging.initialGate!.complete({...data, 'delivery_id': other});
      await Future<void>.delayed(Duration.zero);
      await controller.settled;
      expect(repository.resolutions, hasLength(1));
      expect(routes, hasLength(1));
      await sub.cancel();
    },
  );
}
