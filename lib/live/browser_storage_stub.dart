import 'dart:io';

import '../platform/storage/native_session_storage.dart';

// Unsupported desktop/demo tests retain their prior isolated memory adapter.
// A mobile app must install SQLite; it can never silently use this map.
final _values = <String, String>{};
NativeSessionStorage? get _native => Platform.isIOS || Platform.isAndroid
    ? NativeSessionStorage.current
    : NativeSessionStorage.installed;

String? readSessionValue(String key) =>
    _native?.read(key) ?? (_native == null ? _values[key] : null);
void writeSessionValue(String key, String value) {
  final native = _native;
  if (native != null) {
    native.write(key, value);
  } else {
    _values[key] = value;
  }
}

void removeSessionValue(String key) {
  final native = _native;
  if (native != null) {
    native.remove(key);
  } else {
    _values.remove(key);
  }
}

void clearInviteFromAddress() {}
void clearAuthCallbackFromAddress() {}
