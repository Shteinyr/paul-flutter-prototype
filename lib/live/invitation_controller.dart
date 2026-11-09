import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

String newInvitationToken() {
  final random = Random.secure();
  return List.generate(
    32,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class LiveInvitation {
  const LiveInvitation({
    required this.id,
    required this.token,
    required this.code,
    required this.expiresAt,
    required this.lifetime,
  });
  final String id;
  final String token;
  final String code;
  final DateTime expiresAt;
  // Derived from server time and reduced by request time. Device wall-clock
  // changes cannot extend an invitation on screen.
  final Duration lifetime;
}

abstract interface class InvitationIssuer {
  Future<LiveInvitation> issue(String token);
  Future<void> revoke(String id);
}

class InvitationRenewalRequired implements Exception {}

class InvitationController extends ChangeNotifier {
  InvitationController(this._issuer, {Duration Function()? elapsed})
    : _elapsed = elapsed;
  final InvitationIssuer _issuer;
  final Duration Function()? _elapsed;
  Duration _startedAt = Duration.zero;
  final _age = Stopwatch();
  Timer? _timer;
  LiveInvitation? invitation;
  String? error;
  bool loading = false;
  bool _active = false;
  bool _disposed = false;
  String? _pendingToken;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);

  Duration get remaining {
    final value = invitation?.lifetime ?? Duration.zero;
    final elapsed = _elapsed;
    final age = elapsed == null ? _age.elapsed : elapsed() - _startedAt;
    final left = value - age;
    return left.isNegative ? Duration.zero : left;
  }

  bool get usable => invitation != null && remaining > Duration.zero;

  void start() {
    _active = true;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void pause() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    if (!_active || _disposed) return;
    if (!usable && !loading && DateTime.now().isAfter(_retryAfter)) {
      unawaited(refresh());
    } else {
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    if (loading || _disposed) return;
    loading = true;
    error = null;
    invitation = null;
    notifyListeners();
    try {
      _pendingToken ??= newInvitationToken();
      final value = await _issuer.issue(_pendingToken!);
      if (_disposed) return;
      _pendingToken = null;
      invitation = value;
      _startedAt = _elapsed?.call() ?? Duration.zero;
      _age
        ..reset()
        ..start();
    } catch (problem) {
      if (_disposed) return;
      if (problem is InvitationRenewalRequired) _pendingToken = null;
      // A retry uses the same token. The server preserves its first expiry.
      error =
          'Could not refresh your invitation. Check your connection and retry.';
      _retryAfter = DateTime.now().add(const Duration(seconds: 15));
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> revoke() async {
    final current = invitation;
    if (current == null || loading || _disposed) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      await _issuer.revoke(current.id);
      if (_disposed) return;
      invitation = null;
      _pendingToken = null;
    } catch (_) {
      if (!_disposed) error = 'Could not revoke the invitation. Please retry.';
    } finally {
      loading = false;
      if (!_disposed) notifyListeners();
    }
    if (_active && invitation == null) await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    _age.stop();
    super.dispose();
  }
}
