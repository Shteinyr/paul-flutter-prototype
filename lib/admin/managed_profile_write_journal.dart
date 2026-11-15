import 'dart:convert';

import '../platform/storage/account_value_store.dart';
import '../profile/user_profile.dart';

/// One committed record contains both the editable draft and the exact command.
/// Create uses a fixed slot; its stable operation ID recovers the server reservation.
class ManagedProfileWriteJournal {
  ManagedProfileWriteJournal(String actorId, String? profileId)
    : _store = AccountValueStore(actorId),
      _key = 'managed.profile.${profileId ?? 'create'}';
  final AccountValueStore _store;
  final String _key;
  String? _encoded;
  Map<String, dynamic>? _value;
  bool get isCurrent => _store.read(_key) == _encoded;

  void load() {
    _encoded = _store.read(_key);
    _value = _encoded == null
        ? null
        : jsonDecode(_encoded!) as Map<String, dynamic>;
  }

  UserProfile? get draft =>
      _value == null ? null : UserProfile.decode(_value!['draft'] as String);
  UserProfile? get base =>
      _value == null ? null : UserProfile.decode(_value!['base'] as String);
  String? get version => _value?['version'] as String?;
  String? get avatarPath => _value?['avatar_path'] as String?;
  Map<String, dynamic>? get pending => _value?['command'] == null
      ? null
      : Map<String, dynamic>.from(_value!['command'] as Map);

  void saveDraft(
    UserProfile draft, {
    required UserProfile base,
    required String? version,
    required String? avatarPath,
  }) {
    if (pending != null) throw StateError('Recover the pending save first.');
    _commit({
      'draft': draft.encode(),
      'base': base.encode(),
      'version': version,
      'avatar_path': avatarPath,
    });
  }

  Map<String, dynamic> prepare(Map<String, dynamic> command) {
    if (pending != null) return pending!;
    if (_value == null) throw StateError('Persist the draft before saving.');
    _commit({..._value!, 'command': command});
    return pending!;
  }

  void reject(String operationId) {
    if (pending?['client_operation_id'] != operationId) return;
    _commit({..._value!}..remove('command'));
  }

  void complete(String operationId) {
    if (pending?['client_operation_id'] != operationId) return;
    _commit(null);
  }

  void _commit(Map<String, dynamic>? value) {
    final encoded = value == null ? null : jsonEncode(value);
    if (!_store.compareAndSwap(_key, _encoded, encoded)) {
      throw const ManagedProfileDraftChanged();
    }
    _encoded = encoded;
    _value = encoded == null
        ? null
        : jsonDecode(encoded) as Map<String, dynamic>;
  }
}

class ManagedProfileDraftChanged implements Exception {
  const ManagedProfileDraftChanged();
  @override
  String toString() =>
      'This draft changed in another editor. Reopen it before editing.';
}
