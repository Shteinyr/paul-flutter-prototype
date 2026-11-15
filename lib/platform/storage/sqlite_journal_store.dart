import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

/// Private application data only. Auth credentials belong to the Auth SDK.
/// Every mutating method returns only after a SQLite FULL-sync commit.
class SqliteJournalStore {
  SqliteJournalStore._(this._database);

  factory SqliteJournalStore.open(String path) {
    if (path.isEmpty || path == ':memory:') {
      throw ArgumentError(
        'A persistent application database path is required.',
      );
    }
    return SqliteJournalStore.fromDatabase(sqlite3.open(path));
  }

  /// Also permits an explicitly supplied in-memory database in unit tests.
  factory SqliteJournalStore.fromDatabase(Database database) {
    final store = SqliteJournalStore._(database);
    try {
      database.execute('PRAGMA busy_timeout = 5000');
      database.execute('PRAGMA journal_mode = WAL');
      database.execute('PRAGMA synchronous = FULL');
      database.execute('PRAGMA foreign_keys = ON');
      store._transaction(() {
        final version = database
            .select('PRAGMA user_version')
            .single
            .values
            .single;
        if (version != 0 && version != 1) {
          throw StateError('Unsupported local journal version.');
        }
        if (version == 0) {
          database.execute('''
            CREATE TABLE scoped_values (
              scope TEXT NOT NULL,
              key TEXT NOT NULL,
              value TEXT NOT NULL,
              PRIMARY KEY(scope, key)
            )
          ''');
          database.execute('''
            CREATE TABLE operations (
              scope TEXT NOT NULL,
              kind TEXT NOT NULL,
              target TEXT NOT NULL,
              operation_id TEXT NOT NULL,
              origin_session_id TEXT,
              payload TEXT NOT NULL,
              phase TEXT NOT NULL DEFAULT 'prepared'
                CHECK(phase IN ('prepared', 'uploaded')),
              PRIMARY KEY(scope, kind, target),
              UNIQUE(scope, operation_id)
            )
          ''');
          database.execute('PRAGMA user_version = 1');
        }
      });
      return store;
    } catch (_) {
      database.close();
      rethrow;
    }
  }

  final Database _database;
  bool _closed = false;

  void _check() {
    if (_closed) throw StateError('Local journal is closed.');
  }

  void _validate(String value) {
    _check();
    if (value.isEmpty || value.length > 512 || value.contains('\u0000')) {
      throw ArgumentError('Invalid local journal key.');
    }
  }

  T _transaction<T>(T Function() action) {
    _check();
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  String? read(String scope, String key) {
    _validate(scope);
    _validate(key);
    final rows = _database.select(
      'SELECT value FROM scoped_values WHERE scope = ? AND key = ?',
      [scope, key],
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  void write(String scope, String key, String value) {
    _validate(scope);
    _validate(key);
    _transaction(
      () => _database.execute(
        '''
      INSERT INTO scoped_values(scope, key, value) VALUES (?, ?, ?)
      ON CONFLICT(scope, key) DO UPDATE SET value = excluded.value
    ''',
        [scope, key, value],
      ),
    );
  }

  void remove(String scope, String key) {
    _validate(scope);
    _validate(key);
    _transaction(
      () => _database.execute(
        'DELETE FROM scoped_values WHERE scope = ? AND key = ?',
        [scope, key],
      ),
    );
  }

  JournalOperation? pending(String scope, String kind, String target) {
    _validate(scope);
    _validate(kind);
    _validate(target);
    final rows = _database.select(
      '''
      SELECT * FROM operations WHERE scope = ? AND kind = ? AND target = ?
    ''',
      [scope, kind, target],
    );
    return rows.isEmpty ? null : JournalOperation._fromRow(rows.single);
  }

  JournalOperation prepare(JournalOperation candidate) {
    _validate(candidate.scope);
    _validate(candidate.kind);
    _validate(candidate.target);
    _validate(candidate.operationId);
    final payload = canonicalJournalJson(candidate.payload);
    return _transaction(() {
      final existing = pending(
        candidate.scope,
        candidate.kind,
        candidate.target,
      );
      if (existing != null) {
        if (canonicalJournalJson(existing.payload) != payload) {
          throw PendingJournalConflict(existing);
        }
        // A retry after process death adopts the first committed ID.
        return existing;
      }
      _database.execute(
        '''
        INSERT INTO operations(scope, kind, target, operation_id,
          origin_session_id, payload) VALUES (?, ?, ?, ?, ?, ?)
      ''',
        [
          candidate.scope,
          candidate.kind,
          candidate.target,
          candidate.operationId,
          candidate.originSessionId,
          payload,
        ],
      );
      return pending(candidate.scope, candidate.kind, candidate.target)!;
    });
  }

  bool markUploaded(JournalOperation operation) {
    _check();
    return _transaction(() {
      _database.execute(
        '''
        UPDATE operations SET phase = 'uploaded'
        WHERE scope = ? AND kind = ? AND target = ? AND operation_id = ?
      ''',
        [
          operation.scope,
          operation.kind,
          operation.target,
          operation.operationId,
        ],
      );
      return _database.updatedRows == 1;
    });
  }

  bool complete(JournalOperation operation) {
    _check();
    return _transaction(() {
      _database.execute(
        '''
        DELETE FROM operations
        WHERE scope = ? AND kind = ? AND target = ? AND operation_id = ?
      ''',
        [
          operation.scope,
          operation.kind,
          operation.target,
          operation.operationId,
        ],
      );
      return _database.updatedRows == 1;
    });
  }

  /// Explicit account deletion only. Logout must retain uncertain operations.
  void deleteScope(String scope) {
    _validate(scope);
    _transaction(() {
      _database.execute('DELETE FROM operations WHERE scope = ?', [scope]);
      _database.execute('DELETE FROM scoped_values WHERE scope = ?', [scope]);
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _database.close();
  }
}

class JournalOperation {
  JournalOperation({
    required this.scope,
    required this.kind,
    required this.target,
    required this.operationId,
    required Map<String, dynamic> payload,
    this.originSessionId,
    this.uploaded = false,
  }) : payload = Map.unmodifiable(
         jsonDecode(canonicalJournalJson(payload)) as Map<String, dynamic>,
       );

  final String scope;
  final String kind;
  final String target;
  final String operationId;
  final String? originSessionId;
  final Map<String, dynamic> payload;
  final bool uploaded;

  factory JournalOperation._fromRow(Row row) => JournalOperation(
    scope: row['scope'] as String,
    kind: row['kind'] as String,
    target: row['target'] as String,
    operationId: row['operation_id'] as String,
    originSessionId: row['origin_session_id'] as String?,
    payload: jsonDecode(row['payload'] as String) as Map<String, dynamic>,
    uploaded: row['phase'] == 'uploaded',
  );
}

class PendingJournalConflict implements Exception {
  const PendingJournalConflict(this.pending);
  final JournalOperation pending;
  @override
  String toString() => 'Finish or recover the pending operation first.';
}

String canonicalJournalJson(Object? value) {
  Object? normalize(Object? item) {
    if (item is Map) {
      if (item.keys.any((key) => key is! String)) {
        throw const FormatException('Journal object keys must be strings.');
      }
      final keys = item.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: normalize(item[key])};
    }
    if (item is List) return item.map(normalize).toList();
    return item;
  }

  return jsonEncode(normalize(value));
}
