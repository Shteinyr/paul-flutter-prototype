import '../../live/chat_controller.dart';
import 'native_session_storage.dart';
import 'profile_write_journal.dart';
import 'sqlite_journal_store.dart';

class SqliteChatStateStore implements ChatStateStore {
  const SqliteChatStateStore(this.database, {required this.accountId});
  final SqliteJournalStore database;
  final String accountId;

  void _check(String userId) {
    // Community adds a journal prefix, never a different account.
    if (userId != accountId &&
        userId != 'community.$accountId' &&
        !userId.startsWith('community.close.$accountId.')) {
      throw StateError('Local journal account changed.');
    }
  }

  @override
  Future<String?> read(String userId) async {
    _check(userId);
    return database.read(accountStorageScope(accountId), 'journal:$userId');
  }

  @override
  Future<void> write(String userId, String state) async {
    _check(userId);
    database.write(accountStorageScope(accountId), 'journal:$userId', state);
  }
}

class SqliteProfileWriteJournal implements ProfileWriteJournal {
  const SqliteProfileWriteJournal(this.database);
  final SqliteJournalStore database;

  PendingProfileWrite _decode(JournalOperation operation) {
    final write = PendingProfileWrite.restore(
      operationId: operation.operationId,
      originSessionId: operation.originSessionId,
      uploaded: operation.uploaded,
      payload: operation.payload,
    );
    if (operation.scope != accountStorageScope(write.actorId) ||
        operation.target != write.profileId) {
      throw const FormatException('Saved operation account mismatch.');
    }
    return write;
  }

  JournalOperation _operation(PendingProfileWrite write) => JournalOperation(
    scope: accountStorageScope(write.actorId),
    kind: 'profile',
    target: write.profileId,
    operationId: write.operationId,
    originSessionId: write.originSessionId,
    payload: write.payload,
  );

  @override
  Future<PendingProfileWrite?> read(String actorId, String profileId) async {
    final pending = database.pending(
      accountStorageScope(actorId),
      'profile',
      profileId,
    );
    return pending == null ? null : _decode(pending);
  }

  @override
  Future<PendingProfileWrite> prepare(PendingProfileWrite candidate) async =>
      _decode(database.prepare(_operation(candidate)));
  @override
  Future<void> markUploaded(PendingProfileWrite pending) async {
    if (!database.markUploaded(_operation(pending))) {
      throw StateError('Pending avatar upload changed.');
    }
  }

  @override
  Future<void> complete(PendingProfileWrite pending) async {
    database.complete(_operation(pending));
  }
}
