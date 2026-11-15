import 'sqlite_journal_store.dart';

/// Bound instances keep old async work in its original account namespace.
/// Bootstrap installs the database BEFORE building any live widget.
class NativeSessionStorage {
  NativeSessionStorage(this.database, this.scope) {
    if (scope.isEmpty) {
      throw ArgumentError('A local storage scope is required.');
    }
  }
  final SqliteJournalStore database;
  final String scope;
  static NativeSessionStorage? _current;

  static NativeSessionStorage get current =>
      _current ??
      (throw StateError('Initialize native SQLite before the app.'));
  static NativeSessionStorage? get installed => _current;

  static void install(SqliteJournalStore database, {required String scope}) {
    _current = NativeSessionStorage(database, scope);
  }

  static void unbind() => _current = null;

  NativeSessionStorage account(String userId) =>
      NativeSessionStorage(database, accountStorageScope(userId));

  String? read(String key) => database.read(scope, key);
  void write(String key, String value) => database.write(scope, key, value);
  void remove(String key) => database.remove(scope, key);
}

String accountStorageScope(String userId) {
  if (userId.isEmpty || userId.contains('\u0000')) {
    throw ArgumentError('An account identifier is required.');
  }
  return 'account:$userId';
}
