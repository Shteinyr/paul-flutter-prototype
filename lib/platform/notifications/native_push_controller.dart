import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../live/chat_api.dart';
import '../../push/push_api.dart';
import 'native_messaging.dart';
import 'native_push_api.dart';
import 'native_push_store.dart';

class _Identity {
  const _Identity(this.userId, this.sessionId, this.repository);
  final String userId, sessionId;
  final NativePushRepository repository;
}

class NativePushController {
  NativePushController({required this.messaging, required this.store}) {
    _tokens = messaging.tokenChanges.listen(
      (token) {
        final generation = _generation;
        unawaited(_queue(() => _refresh(generation, token: token)));
      },
      onError: (Object _) {
        error = 'token_unavailable';
      },
    );
    _taps = messaging.taps.listen(_receiveTap, onError: (Object _) {});
    _foreground = messaging.foreground.listen((data) {
      final generation = _generation;
      unawaited(
        _queue(() async {
          if (!_current(generation)) return;
          final envelope = NativePushEnvelope.parse(data),
              identity = _identity!;
          if (envelope == null ||
              envelope.click.recipientId != identity.userId) {
            return;
          }
          final binding = await store.read(identity.userId, identity.sessionId);
          if (_current(generation) &&
              binding?.bindingId == envelope.click.bindingId) {
            _activities.add(envelope);
            final presenter = _foregroundPresenter;
            if (enabled && !messaging.isApple && presenter != null) {
              await presenter.showForeground(envelope);
            }
          }
        }),
      );
    }, onError: (Object _) {});
    unawaited(_initialTap());
  }
  final MessagingPort messaging;
  final NativePushStore store;
  ForegroundMessagingPort? get _foregroundPresenter =>
      messaging is ForegroundMessagingPort
      ? messaging as ForegroundMessagingPort
      : null;
  NativePushRetirementStore? get _retirementStore =>
      store is NativePushRetirementStore
      ? store as NativePushRetirementStore
      : null;
  late final StreamSubscription<String> _tokens;
  late final StreamSubscription<Map<String, dynamic>> _taps, _foreground;
  final _routes = StreamController<PushRoute>.broadcast();
  final _activities = StreamController<NativePushEnvelope>.broadcast();
  Stream<PushRoute> get routes => _routes.stream;
  Stream<NativePushEnvelope> get foreground => _activities.stream;
  Future<void> _work = Future.value();
  Future<void> get settled => _work;
  _Identity? _identity;
  NativePushEnvelope? _pendingTap;
  int _generation = 0;
  int _tapRevision = 0;
  bool _disposed = false;
  bool enabled = false;
  bool waitingForApns = false;
  String? error;
  NativePushPermission permission = NativePushPermission.notDetermined;
  final _handled = <String>{};

  Future<void> _queue(Future<void> Function() work) {
    final result = _work.catchError((Object _) {}).then((_) async {
      if (!_disposed) await work();
    });
    _work = result.catchError((Object _) {
      if (!_disposed) error = 'notification_unavailable';
    });
    return _work;
  }

  bool _current(int generation) =>
      !_disposed && generation == _generation && _identity != null;

  Future<void> _initialTap() async {
    final revision = _tapRevision;
    try {
      final data = await messaging.initialTap();
      if (data != null && !_disposed && revision == _tapRevision) {
        _receiveTap(data);
      }
    } catch (_) {
      if (!_disposed) error = 'notification_unavailable';
    }
  }

  void _receiveTap(Map<String, dynamic> data) {
    if (_disposed) return;
    final envelope = NativePushEnvelope.parse(data);
    if (envelope == null) return;
    _tapRevision++;
    _pendingTap = envelope;
    final generation = _generation;
    unawaited(_queue(() => _drainTap(generation)));
  }

  Future<void> setIdentity({
    required String? userId,
    required String? sessionId,
    required bool admitted,
    NativePushRepository? repository,
  }) {
    if (admitted &&
        (userId == null || sessionId == null || repository == null)) {
      throw ArgumentError(
        'Admitted notification identity requires its repository.',
      );
    }
    final previous = _identity;
    final generation = ++_generation;
    _identity = null;
    enabled = false;
    waitingForApns = false;
    return _queue(() async {
      final changed =
          !admitted ||
          userId != previous?.userId ||
          sessionId != previous?.sessionId;
      if (previous != null && changed) await _clear(previous);
      if (previous == null && !admitted) await _retireDevice();
      if (_disposed || generation != _generation || !admitted) return;
      _identity = _Identity(userId!, sessionId!, repository!);
      await _refresh(generation);
      await _drainTap(generation);
    });
  }

  Future<void> _clear(_Identity identity) async {
    // Persist retirement before either remote unsubscription or SDK mutation.
    await _markRetirement();
    try {
      final binding = await store.read(identity.userId, identity.sessionId);
      if (binding != null) {
        await identity.repository.unsubscribe(binding.bindingId);
      }
    } catch (_) {
      // Deleting the device token also retires a server binding whose logout
      // acknowledgement was lost. No further request uses the new account.
    } finally {
      await _retireDevice();
      await store.remove(identity.userId, identity.sessionId);
    }
  }

  bool _retirementPending = false;
  Future<void> _markRetirement() async {
    _retirementPending = true;
    final durable = _retirementStore;
    if (durable != null) {
      await durable.setRetirementPending(true);
    }
  }

  Future<bool> _retireDevice() async {
    await _markRetirement();
    final durable = _retirementStore;
    final presenter = _foregroundPresenter;
    if (presenter != null) {
      try {
        await presenter.clearForeground();
      } catch (_) {}
    }
    try {
      await messaging.deleteToken();
      if (durable != null) {
        await durable.setRetirementPending(false);
      }
      _retirementPending = false;
      return true;
    } catch (_) {
      error = 'notification_unavailable';
      return false;
    }
  }

  Future<void> requestPermission() {
    final generation = _generation;
    return _queue(() async {
      if (!_current(generation)) return;
      permission = await messaging.permission(request: true);
      if (_current(generation)) await _refresh(generation);
    });
  }

  Future<void> refresh() {
    final generation = _generation;
    return _queue(() async {
      if (generation != _generation || _disposed) return;
      if (_identity == null) {
        final durable = _retirementStore;
        if (_retirementPending ||
            (durable != null && await durable.retirementPending())) {
          if (generation == _generation && !_disposed) await _retireDevice();
        }
        return;
      }
      await _refresh(generation);
    });
  }

  Future<void> _refresh(int generation, {String? token}) async {
    if (!_current(generation)) return;
    final identity = _identity!;
    error = null;
    enabled = false;
    final durable = _retirementStore;
    final pending =
        _retirementPending ||
        (durable != null && await durable.retirementPending());
    if (!_current(generation)) return;
    if (pending && !await _retireDevice()) return;
    if (!_current(generation)) return;
    permission = await messaging.permission();
    if (!_current(generation)) return;
    if (permission != NativePushPermission.authorized &&
        permission != NativePushPermission.provisional) {
      await _clear(identity);
      return;
    }
    if (messaging.isApple && await messaging.apnsToken() == null) {
      if (_current(generation)) waitingForApns = true;
      return;
    }
    if (!_current(generation)) return;
    waitingForApns = false;
    final deviceToken = token ?? await messaging.token();
    if (!_current(generation)) return;
    if (deviceToken == null || deviceToken.isEmpty) {
      error = 'token_unavailable';
      return;
    }
    final previous = await store.read(identity.userId, identity.sessionId);
    if (!_current(generation)) return;
    final binding = NativePushBinding(
      identity.userId,
      identity.sessionId,
      previous?.bindingId ?? newChatOperationId(),
      sha256.convert(utf8.encode(deviceToken)).toString(),
    );
    // Save the proposed ID before remote registration, so lost ACK and logout
    // can reconcile the exact same binding after a process restart.
    await store.write(binding);
    if (!_current(generation)) return;
    final canonical = await identity.repository.subscribe(
      binding.bindingId,
      deviceToken,
      messaging.isApple ? 'ios' : 'android',
    );
    if (!_current(generation)) return;
    await store.write(
      NativePushBinding(
        identity.userId,
        identity.sessionId,
        canonical,
        binding.tokenDigest,
      ),
    );
    if (_current(generation)) {
      enabled = true;
      await _drainTap(generation);
    }
  }

  Future<void> _drainTap(int generation) async {
    if (!_current(generation)) return;
    final envelope = _pendingTap;
    if (envelope == null) return;
    final identity = _identity!;
    if (envelope.click.recipientId != identity.userId) {
      _pendingTap = null;
      return;
    }
    final binding = await store.read(identity.userId, identity.sessionId);
    if (!_current(generation)) return;
    if (binding?.bindingId != envelope.click.bindingId) {
      _pendingTap = null;
      return;
    }
    if (_handled.contains(envelope.click.deliveryId)) {
      _pendingTap = null;
      return;
    }
    final route = await identity.repository.resolve(envelope.click);
    if (!_current(generation) || !identical(envelope, _pendingTap)) return;
    _pendingTap = null;
    if (_handled.length >= 128) _handled.remove(_handled.first);
    _handled.add(envelope.click.deliveryId);
    _routes.add(route);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _identity = null;
    await Future.wait([_tokens.cancel(), _taps.cancel(), _foreground.cancel()]);
    await _work;
    final presenter = _foregroundPresenter;
    if (presenter != null) {
      await presenter.disposeForeground();
    }
    await _routes.close();
    await _activities.close();
  }
}
