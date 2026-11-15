import 'package:supabase_flutter/supabase_flutter.dart';
import 'browser_storage.dart';

const keepSignedInKey = 'paul.auth.keep-signed-in.v1';

/// Retains the SDK's existing storage key, preserving admitted sessions during
/// rollout. Opting out clears disk storage while keeping the current run alive.
class KeepSignedInStorage extends LocalStorage {
  KeepSignedInStorage(this.delegate, {bool Function()? remember})
    : _remember = remember ?? (() => readSessionValue(keepSignedInKey) != '0');
  final LocalStorage delegate;
  final bool Function() _remember;
  String? _volatile;
  @override
  Future<void> initialize() async {
    await delegate.initialize();
    if (!_remember()) await delegate.removePersistedSession();
  }

  @override
  Future<bool> hasAccessToken() async =>
      _remember() ? delegate.hasAccessToken() : _volatile != null;
  @override
  Future<String?> accessToken() async =>
      _remember() ? delegate.accessToken() : _volatile;
  @override
  Future<void> removePersistedSession() async {
    _volatile = null;
    await delegate.removePersistedSession();
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    _volatile = persistSessionString;
    if (_remember()) {
      await delegate.persistSession(persistSessionString);
    } else {
      await delegate.removePersistedSession();
    }
  }
}
