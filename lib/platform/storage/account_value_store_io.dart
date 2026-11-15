import 'dart:io';

import 'native_session_storage.dart';
import 'account_value_store_web.dart' as fallback;

class AccountValueStore {
  AccountValueStore(this.accountId)
    : _native = Platform.isIOS || Platform.isAndroid
          ? NativeSessionStorage.current
          : NativeSessionStorage.installed,
      _fallback = fallback.AccountValueStore(accountId);
  final String accountId;
  final NativeSessionStorage? _native;
  final fallback.AccountValueStore _fallback;
  String? read(String key) => _native == null
      ? _fallback.read(key)
      : _native.database.read(accountStorageScope(accountId), key);
  void write(String key, String value) {
    if (_native == null) {
      _fallback.write(key, value);
    } else {
      _native.database.write(accountStorageScope(accountId), key, value);
    }
  }

  bool compareAndSwap(String key, String? expected, String? value) =>
      _native == null
      ? _fallback.compareAndSwap(key, expected, value)
      : _native.database.compareAndSwap(
          accountStorageScope(accountId),
          key,
          expected,
          value,
        );
}
