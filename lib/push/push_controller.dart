import 'package:flutter/foundation.dart';
import 'push_api.dart';
import 'push_browser_types.dart';

class PushController extends ChangeNotifier {
  PushController(this.browser, this.repository);
  final PushBrowser browser;
  final PushRepository repository;
  BrowserPushState state = const BrowserPushState(
    supported: false,
    permission: 'checking',
  );
  PushConfiguration? configuration;
  bool busy = false;
  bool enabled = false;
  bool ready = false;
  String? error;
  int _generation = 0;
  bool _disposed = false;
  String? _bindingId;

  bool _current(int generation) =>
      !_disposed && generation == _generation && repository.current;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _message(Object failure) => failure is PushException
      ? failure.toString()
      : const PushException('server_unavailable').toString();

  Future<void> initialize() async {
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      await browser.identity(repository.userId, repository.sessionId);
      if (!_current(generation)) return;
      await _refresh(generation);
    } catch (failure) {
      if (_current(generation)) error = _message(failure);
    } finally {
      if (_current(generation)) {
        ready = true;
        busy = false;
        _notify();
      }
    }
  }

  Future<void> _refresh(int generation) async {
    final inspected = await browser.inspect();
    if (!_current(generation)) return;
    state = inspected;
    enabled = false;
    _bindingId = inspected.bindingId;
    if (!state.supported) return;
    if (state.permission != 'granted' && _bindingId != null) {
      final id = await browser.clear(repository.userId, repository.sessionId);
      if (!_current(generation)) return;
      if (id != null) await repository.unsubscribe(id);
      _bindingId = null;
    }
    final config = await repository.config();
    if (!_current(generation)) return;
    configuration = config;
    final binding = _bindingId;
    if (state.permission == 'granted' &&
        state.active &&
        binding != null &&
        config.enabled) {
      final active = await repository.status(binding);
      if (!_current(generation)) return;
      enabled = active;
      if (!active) {
        await browser.clear(repository.userId, repository.sessionId);
        if (_current(generation)) _bindingId = null;
      }
    }
  }

  Future<void> refresh() async {
    if (busy || _disposed || !repository.current) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    try {
      await _refresh(generation);
    } catch (failure) {
      if (_current(generation)) error = _message(failure);
    } finally {
      if (_current(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> enable() async {
    final key = configuration?.publicKey;
    if (busy ||
        !ready ||
        !state.supported ||
        configuration?.enabled != true ||
        key == null ||
        !repository.current) {
      return;
    }
    final generation = ++_generation;
    busy = true;
    error = null;
    _notify();
    // Start the permission call in this gesture, before any asynchronous work.
    final consent = state.permission == 'granted'
        ? Future.value('granted')
        : browser.permission();
    try {
      final permission = await consent;
      if (!_current(generation)) return;
      state = BrowserPushState(supported: true, permission: permission);
      if (permission != 'granted') {
        enabled = false;
        return;
      }
      final prepared = await browser.prepare(repository.userId, key);
      if (!_current(generation)) return;
      final canonical = await repository.subscribe(prepared);
      if (!_current(generation)) return;
      await browser.commit(repository.userId, prepared.bindingId, canonical);
      if (!_current(generation)) return;
      _bindingId = canonical;
      state = BrowserPushState(
        supported: true,
        permission: 'granted',
        bindingId: canonical,
        active: true,
      );
      enabled = true;
    } catch (failure) {
      if (_current(generation)) {
        enabled = false;
        error = _message(failure);
      }
    } finally {
      if (_current(generation)) {
        busy = false;
        _notify();
      }
    }
  }

  /// Also used before sign-out. Local revocation precedes the network request.
  Future<void> disable() async {
    if (_disposed || !repository.current) return;
    final generation = ++_generation;
    busy = true;
    enabled = false;
    error = null;
    _notify();
    String? binding = _bindingId;
    Object? failure;
    try {
      binding =
          await browser.clear(repository.userId, repository.sessionId) ??
          binding;
    } catch (error) {
      failure = error;
    }
    try {
      if (!_current(generation)) return;
      _bindingId = null;
      if (binding != null) await repository.unsubscribe(binding);
    } catch (error) {
      failure = error;
    } finally {
      if (_current(generation) && failure != null) error = _message(failure);
    }
    if (_current(generation)) {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
