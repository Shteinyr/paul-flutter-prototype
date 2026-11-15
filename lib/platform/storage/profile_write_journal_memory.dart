import 'profile_write_journal.dart';

/// Compatibility adapter for the existing web/demo flow and VM fixtures.
/// Installed iOS/Android apps use the SQLite factory instead.
class MemoryProfileWriteJournal implements ProfileWriteJournal {
  final _values = <(String, String), PendingProfileWrite>{};
  @override
  Future<PendingProfileWrite?> read(String actorId, String profileId) async =>
      _values[(actorId, profileId)];
  @override
  Future<PendingProfileWrite> prepare(PendingProfileWrite candidate) async {
    final key = (candidate.actorId, candidate.profileId);
    final existing = _values[key];
    if (existing != null) return existing;
    return _values[key] = candidate;
  }

  @override
  Future<void> markUploaded(PendingProfileWrite pending) async {
    final key = (pending.actorId, pending.profileId);
    if (_values[key]?.operationId != pending.operationId) {
      throw StateError('Pending avatar upload changed.');
    }
    _values[key] = PendingProfileWrite.restore(
      operationId: pending.operationId,
      originSessionId: pending.originSessionId,
      uploaded: true,
      payload: pending.payload,
    );
  }

  @override
  Future<void> complete(PendingProfileWrite pending) async {
    final key = (pending.actorId, pending.profileId);
    if (_values[key]?.operationId == pending.operationId) _values.remove(key);
  }
}
