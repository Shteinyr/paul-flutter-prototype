import 'dart:convert';

import '../../push/push_browser_types.dart';
import '../storage/native_session_storage.dart';
import '../storage/sqlite_journal_store.dart';

class NativePushBinding {
  const NativePushBinding(
    this.userId,
    this.sessionId,
    this.bindingId,
    this.tokenDigest,
  );
  final String userId, sessionId, bindingId, tokenDigest;
}

abstract interface class NativePushStore {
  Future<NativePushBinding?> read(String userId, String sessionId);
  Future<void> write(NativePushBinding binding);
  Future<void> remove(String userId, String sessionId);
}

class SqliteNativePushStore implements NativePushStore {
  const SqliteNativePushStore(this.database);
  final SqliteJournalStore database;
  String _key(String sessionId) => 'native-push-binding:$sessionId';
  @override
  Future<NativePushBinding?> read(String userId, String sessionId) async {
    final source = database.read(accountStorageScope(userId), _key(sessionId));
    if (source == null) return null;
    final value = jsonDecode(source);
    if (value is! Map ||
        value['version'] != 1 ||
        value['user_id'] != userId ||
        value['session_id'] != sessionId ||
        value['binding_id'] is! String ||
        !pushUuid.hasMatch(value['binding_id'] as String) ||
        value['token_digest'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['token_digest'] as String)) {
      throw const FormatException('Invalid saved notification binding.');
    }
    return NativePushBinding(
      userId,
      sessionId,
      value['binding_id'] as String,
      value['token_digest'] as String,
    );
  }

  @override
  Future<void> write(NativePushBinding binding) async {
    database.write(
      accountStorageScope(binding.userId),
      _key(binding.sessionId),
      jsonEncode({
        'version': 1,
        'user_id': binding.userId,
        'session_id': binding.sessionId,
        'binding_id': binding.bindingId,
        'token_digest': binding.tokenDigest,
      }),
    );
  }

  @override
  Future<void> remove(String userId, String sessionId) async =>
      database.remove(accountStorageScope(userId), _key(sessionId));
}
