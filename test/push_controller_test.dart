import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/push/push_api.dart';
import 'package:paul_demo/push/push_browser_types.dart';
import 'package:paul_demo/push/push_controller.dart';

const user = '10000000-0000-4000-8000-000000000001';
const session = '10000000-0000-4000-8000-000000000002';
const proposed = '10000000-0000-4000-8000-000000000003';
const canonical = '10000000-0000-4000-8000-000000000004';

class Browser implements PushBrowser {
  BrowserPushState state = const BrowserPushState(
    supported: true,
    permission: 'default',
  );
  String consent = 'granted';
  int prompts = 0;
  int prepares = 0;
  int commits = 0;
  int clears = 0;
  String? binding;
  @override
  Stream<PushClick> get clicks => const Stream.empty();
  @override
  PushClick? takeClick() => null;
  @override
  Future<void> identity(String? userId, String? sessionId) async {}
  @override
  Future<BrowserPushState> inspect() async => state;
  @override
  Future<String> permission() {
    prompts++;
    return Future.value(consent);
  }

  @override
  Future<PreparedPush> prepare(String userId, String key) async {
    prepares++;
    binding = proposed;
    return const PreparedPush(proposed, {'endpoint': 'synthetic'});
  }

  @override
  Future<void> commit(
    String userId,
    String proposedId,
    String canonicalId,
  ) async {
    expect(proposedId, proposed);
    commits++;
    binding = canonicalId;
  }

  @override
  Future<String?> clear(String userId, String sessionId) async {
    clears++;
    final old = binding ?? state.bindingId;
    binding = null;
    return old;
  }

  @override
  void dispose() {}
}

class Repository implements PushRepository {
  @override
  String get userId => user;
  @override
  String get sessionId => session;
  @override
  bool current = true;
  bool available = true;
  bool active = true;
  int configs = 0;
  int subscriptions = 0;
  final detached = <String>[];
  Completer<String>? pending;
  bool detachFails = false;
  @override
  Future<PushConfiguration> config() async {
    configs++;
    return PushConfiguration(available, available ? 'synthetic-key' : null);
  }

  @override
  Future<String> subscribe(PreparedPush push) async {
    subscriptions++;
    return pending?.future ?? canonical;
  }

  @override
  Future<bool> status(String id) async => active;
  @override
  Future<void> unsubscribe(String id) async {
    detached.add(id);
    if (detachFails) throw const PushException('server_unavailable');
  }

  @override
  Future<PushRoute> resolve(PushClick click) async =>
      throw UnimplementedError();
}

void main() {
  test(
    'initialization and existing permission never create a subscription or prompt',
    () async {
      final browser = Browser()
        ..state = const BrowserPushState(
          supported: true,
          permission: 'granted',
        );
      final controller = PushController(browser, Repository());
      await controller.initialize();
      expect(controller.ready, isTrue);
      expect(controller.enabled, isFalse);
      expect(browser.prompts, 0);
      expect(browser.prepares, 0);
      controller.dispose();
    },
  );
  test(
    'permission starts in the explicit enable call and commits canonical server binding',
    () async {
      final browser = Browser();
      final repository = Repository();
      final controller = PushController(browser, repository);
      await controller.initialize();
      final enabled = controller.enable();
      expect(browser.prompts, 1);
      await enabled;
      expect(controller.enabled, isTrue);
      expect(browser.binding, canonical);
      expect(repository.subscriptions, 1);
      controller.dispose();
    },
  );
  test(
    'permission denial preserves working app without creating subscriptions',
    () async {
      final browser = Browser()..consent = 'denied';
      final repository = Repository();
      final controller = PushController(browser, repository);
      await controller.initialize();
      await controller.enable();
      expect(controller.state.permission, 'denied');
      expect(controller.busy, isFalse);
      expect(repository.subscriptions, 0);
      expect(browser.commits, 0);
      controller.dispose();
    },
  );
  test('unsupported browser and disabled server never prompt', () async {
    for (final supported in [false, true]) {
      final browser = Browser()
        ..state = BrowserPushState(
          supported: supported,
          permission: supported ? 'default' : 'unsupported',
        );
      final repository = Repository()..available = false;
      final controller = PushController(browser, repository);
      await controller.initialize();
      await controller.enable();
      expect(browser.prompts, 0);
      expect(repository.subscriptions, 0);
      expect(repository.configs, supported ? 1 : 0);
      controller.dispose();
    }
  });
  test(
    'revoked permission clears local binding and detaches server before retry',
    () async {
      final browser = Browser()
        ..state = const BrowserPushState(
          supported: true,
          permission: 'granted',
          bindingId: canonical,
          active: true,
        );
      final repository = Repository();
      final controller = PushController(browser, repository);
      await controller.initialize();
      expect(controller.enabled, isTrue);
      browser.state = const BrowserPushState(
        supported: true,
        permission: 'denied',
        bindingId: canonical,
        active: true,
      );
      await controller.refresh();
      expect(controller.enabled, isFalse);
      expect(browser.clears, 1);
      expect(repository.detached, [canonical]);
      controller.dispose();
    },
  );
  test(
    'logout racing a late subscription ACK cannot reactivate browser binding',
    () async {
      final browser = Browser();
      final repository = Repository()..pending = Completer<String>();
      final controller = PushController(browser, repository);
      await controller.initialize();
      final enabled = controller.enable();
      while (repository.subscriptions == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await controller.disable();
      repository.pending!.complete(canonical);
      await enabled;
      expect(browser.commits, 0);
      expect(browser.binding, isNull);
      expect(controller.enabled, isFalse);
      controller.dispose();
    },
  );
  test(
    'identity change during subscribe drops the ACK without touching new binding',
    () async {
      final browser = Browser();
      final repository = Repository()..pending = Completer<String>();
      final controller = PushController(browser, repository);
      await controller.initialize();
      final enabled = controller.enable();
      while (repository.subscriptions == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      repository.current = false;
      browser.binding = 'new-user-binding';
      repository.pending!.complete(canonical);
      await enabled;
      expect(browser.commits, 0);
      expect(browser.clears, 0);
      expect(browser.binding, 'new-user-binding');
      controller.dispose();
    },
  );
  test(
    'detach network failure retains local revocation and permits sign-out',
    () async {
      final browser = Browser()..binding = canonical;
      final repository = Repository()..detachFails = true;
      final controller = PushController(browser, repository);
      await controller.initialize();
      await controller.disable();
      expect(browser.binding, isNull);
      expect(repository.detached, [canonical]);
      expect(controller.enabled, isFalse);
      expect(controller.error, isNotNull);
      expect(controller.busy, isFalse);
      controller.dispose();
    },
  );
  test(
    'untrusted click identifiers and older unreleased payload are rejected',
    () {
      expect(
        PushClick.parse({
          'version': 1,
          'recipient_user_id': user,
          'binding_id': canonical,
          'delivery_id': proposed,
        }),
        isNotNull,
      );
      expect(
        PushClick.parse({
          'v': 1,
          'recipient_user_id': user,
          'binding_id': canonical,
          'event_id': proposed,
        }),
        isNull,
      );
      expect(
        PushClick.parse({
          'version': 1,
          'recipient_user_id': user,
          'binding_id': canonical,
          'delivery_id': 'https://foreign',
        }),
        isNull,
      );
    },
  );
}
