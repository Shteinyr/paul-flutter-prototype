import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../live/chat_api.dart';
import '../push/push_browser_types.dart';

class DeletionException implements Exception {
  const DeletionException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'identity_changed' || 'sign_in_required' || 'session_revoked' =>
      'Sign in to the original account to retry this deletion.',
    'profile_version_conflict' =>
      'This profile changed. Refresh it before deleting.',
    'deletion_unavailable' =>
      'The deletion has not been confirmed. Retry with the original account.',
    'managed_profile_forbidden' ||
    'admin_forbidden' => 'This profile is unavailable for deletion.',
    'rate_limited' => 'Too many attempts. Wait a minute and retry.',
    _ => 'Could not confirm deletion. Your recovery details are saved. Retry.',
  };
}

class DeletionRecord {
  const DeletionRecord({
    required this.actorId,
    required this.profileId,
    required this.operationId,
    this.receiptToken,
    this.expectedUpdatedAt,
  });
  final String actorId;
  final String profileId;
  final String operationId;
  final String? receiptToken;
  final String? expectedUpdatedAt;
  bool get self => receiptToken != null;
  String get key => 'paul.live.deletion.v1.$operationId';

  factory DeletionRecord.create(
    String actor, {
    String? profileId,
    String? updatedAt,
  }) {
    final random = Random.secure();
    return DeletionRecord(
      actorId: actor,
      profileId: profileId ?? actor,
      operationId: newChatOperationId(),
      receiptToken: profileId == null
          ? List.generate(
              32,
              (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
            ).join()
          : null,
      expectedUpdatedAt: updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'actor_id': actorId,
    'profile_id': profileId,
    'operation_id': operationId,
    'receipt_token': receiptToken,
    'expected_updated_at': expectedUpdatedAt,
  };
  factory DeletionRecord.fromJson(Map<String, dynamic> value) {
    final actor = value['actor_id'];
    final profile = value['profile_id'];
    final operation = value['operation_id'];
    final receipt = value['receipt_token'];
    final revision = value['expected_updated_at'];
    if (value['version'] != 1 ||
        actor is! String ||
        !pushUuid.hasMatch(actor) ||
        profile is! String ||
        !pushUuid.hasMatch(profile) ||
        operation is! String ||
        !pushUuid.hasMatch(operation) ||
        (receipt != null &&
            (receipt is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(receipt))) ||
        (receipt != null && actor != profile) ||
        (receipt == null &&
            (revision is! String || DateTime.tryParse(revision) == null))) {
      throw const FormatException('Invalid deletion recovery record');
    }
    return DeletionRecord(
      actorId: actor,
      profileId: profile,
      operationId: operation,
      receiptToken: receipt as String?,
      expectedUpdatedAt: revision as String?,
    );
  }
}

class DeletionStatus {
  const DeletionStatus(this.operationId, this.complete);
  final String operationId;
  final bool complete;
  factory DeletionStatus.fromJson(
    Map<String, dynamic> data,
    DeletionRecord record,
  ) {
    if (data['operation_id'] != record.operationId ||
        (data['state'] != 'pending' && data['state'] != 'complete')) {
      throw const DeletionException('server_unavailable');
    }
    return DeletionStatus(record.operationId, data['state'] == 'complete');
  }
}

abstract interface class DeletionStore {
  Future<List<DeletionRecord>> read();
  Future<void> write(DeletionRecord record);
  Future<void> remove(DeletionRecord record);
}

class PreferenceDeletionStore implements DeletionStore {
  PreferenceDeletionStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences;
  SharedPreferencesAsync? _preferences;
  SharedPreferencesAsync get _prefs =>
      _preferences ??= SharedPreferencesAsync();
  @override
  Future<List<DeletionRecord>> read() async {
    final keys = await _prefs.getKeys();
    final records = <DeletionRecord>[];
    for (final key in keys.where(
      (key) => key.startsWith('paul.live.deletion.v1.'),
    )) {
      final source = await _prefs.getString(key);
      if (source == null) continue;
      final record = DeletionRecord.fromJson(
        Map<String, dynamic>.from(jsonDecode(source) as Map),
      );
      if (record.key != key) {
        throw const FormatException('Invalid recovery scope');
      }
      records.add(record);
    }
    return records;
  }

  @override
  Future<void> write(DeletionRecord record) =>
      _prefs.setString(record.key, jsonEncode(record.toJson()));
  @override
  Future<void> remove(DeletionRecord record) => _prefs.remove(record.key);
}

abstract interface class DeletionRepository {
  String? get currentUserId;
  Future<DeletionStatus> submit(DeletionRecord record);
  Future<DeletionStatus> status(DeletionRecord record);
  Future<void> clearAuth(String actorId);
}

class SupabaseDeletionApi implements DeletionRepository {
  const SupabaseDeletionApi(this.client);
  final SupabaseClient client;
  @override
  String? get currentUserId => client.auth.currentUser?.id;

  Future<DeletionStatus> _call(
    DeletionRecord record, {
    required bool recovery,
  }) async {
    final unsigned = recovery && record.self;
    if (!unsigned && currentUserId != record.actorId) {
      throw const DeletionException('identity_changed');
    }
    final token = unsigned ? '' : client.auth.currentSession?.accessToken;
    if (token == null) throw const DeletionException('sign_in_required');
    final body = record.self
        ? recovery
              ? {
                  'action': 'deletion_status',
                  'client_operation_id': record.operationId,
                  'receipt_token': record.receiptToken,
                }
              : {
                  'action': 'delete',
                  'expected_user_id': record.actorId,
                  'client_operation_id': record.operationId,
                  'confirm': true,
                  'receipt_token': record.receiptToken,
                }
        : {
            'action': 'delete',
            'profile_id': record.profileId,
            'client_operation_id': record.operationId,
            'confirm': true,
            'expected_updated_at': record.expectedUpdatedAt,
          };
    try {
      final response = await client.functions
          .invoke(
            record.self ? 'account' : 'admin',
            headers: {'Authorization': unsigned ? '' : 'Bearer $token'},
            body: body,
          )
          .timeout(const Duration(seconds: 30));
      return DeletionStatus.fromJson(
        Map<String, dynamic>.from(response.data as Map),
        record,
      );
    } on FunctionException catch (error) {
      final details = error.details;
      throw DeletionException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<DeletionStatus> submit(DeletionRecord record) =>
      _call(record, recovery: false);
  @override
  Future<DeletionStatus> status(DeletionRecord record) =>
      _call(record, recovery: true);
  @override
  Future<void> clearAuth(String actorId) async {
    if (currentUserId == actorId) {
      await client.auth.signOut(scope: SignOutScope.local);
    }
  }
}

class DeletionController extends ChangeNotifier {
  DeletionController(this.repository, this.store);
  final DeletionRepository repository;
  final DeletionStore store;
  final _records = <DeletionRecord>[];
  final _running = <String>{};
  final _beginnings = <String, Future<DeletionRecord?>>{};
  final _confirmed = <String, DeletionStatus>{};
  final errors = <String, String>{};
  final _complete = <String>{};
  final _rejected = <String>{};
  Timer? _timer;
  Future<bool>? _loading;
  bool _loaded = false;
  bool _disposed = false;
  String? loadError;
  List<DeletionRecord> get records => List.unmodifiable(_records);
  bool confirmed(DeletionRecord record) =>
      _confirmed.containsKey(record.operationId);
  bool busy(DeletionRecord record) => _running.contains(record.operationId);
  bool complete(DeletionRecord record) =>
      _complete.contains(record.operationId);
  bool rejected(DeletionRecord record) =>
      _rejected.contains(record.operationId);
  bool finished(DeletionRecord record) => complete(record) || rejected(record);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> load() {
    final running = _loading;
    if (running != null) return running;
    final operation = _load();
    _loading = operation;
    unawaited(operation.whenComplete(() => _loading = null));
    return operation;
  }

  Future<bool> _load() async {
    if (_loaded) return true;
    try {
      final stored = await store.read();
      if (_disposed) return false;
      _records.addAll(stored);
      _loaded = true;
      loadError = null;
      _notify();
      for (final record in stored) {
        if (record.self || repository.currentUserId == record.actorId) {
          unawaited(refresh(record));
        }
      }
      _timer = Timer.periodic(const Duration(seconds: 10), (_) {
        for (final record in _records.toList()) {
          if (!finished(record) &&
              !errors.containsKey(record.operationId) &&
              (record.self || repository.currentUserId == record.actorId)) {
            unawaited(refresh(record));
          }
        }
      });
      return true;
    } catch (_) {
      loadError =
          'Could not restore account-deletion recovery. Retry before deleting.';
      _notify();
      return false;
    }
  }

  Future<DeletionRecord?> begin(
    String actorId, {
    String? profileId,
    String? updatedAt,
  }) {
    final key = '$actorId.${profileId ?? actorId}';
    final running = _beginnings[key];
    if (running != null) return running;
    final operation = _begin(
      actorId,
      profileId: profileId,
      updatedAt: updatedAt,
    );
    _beginnings[key] = operation;
    unawaited(operation.whenComplete(() => _beginnings.remove(key)));
    return operation;
  }

  Future<DeletionRecord?> _begin(
    String actorId, {
    String? profileId,
    String? updatedAt,
  }) async {
    if (!await load() || _disposed || repository.currentUserId != actorId) {
      return null;
    }
    final profile = profileId ?? actorId;
    final existing = _records
        .where(
          (item) =>
              item.actorId == actorId &&
              item.profileId == profile &&
              !finished(item),
        )
        .firstOrNull;
    if (existing != null) {
      await retry(existing);
      return existing;
    }
    final record = DeletionRecord.create(
      actorId,
      profileId: profileId,
      updatedAt: updatedAt,
    );
    try {
      // Persist before the request and independently of SDK session storage.
      await store.write(record);
    } catch (_) {
      loadError = 'Could not save deletion recovery. Retry before deleting.';
      _notify();
      return null;
    }
    if (_disposed) return null;
    loadError = null;
    _records.add(record);
    _notify();
    await retry(record);
    return record;
  }

  Future<void> retry(DeletionRecord record) => _run(record, submit: true);
  Future<void> refresh(DeletionRecord record) => _run(record, submit: false);
  Future<void> _run(DeletionRecord record, {required bool submit}) async {
    if (_disposed || busy(record) || finished(record)) return;
    _running.add(record.operationId);
    errors.remove(record.operationId);
    _notify();
    try {
      var status = _confirmed[record.operationId];
      if (status == null || !status.complete) {
        try {
          status = submit
              ? await repository.submit(record)
              : await repository.status(record);
        } catch (_) {
          // A committed delete can revoke Auth before its acknowledgement arrives.
          if (!record.self || !submit) rethrow;
          status = await repository.status(record);
        }
      }
      _confirmed[record.operationId] = status;
      if (record.self) {
        try {
          await repository.clearAuth(record.actorId);
        } catch (_) {
          // The recovery receipt remains available after a revoked session.
        }
      }
      if (status.complete) {
        await store.remove(record);
        _complete.add(record.operationId);
      }
    } catch (failure) {
      if (!record.self &&
          failure is DeletionException &&
          failure.code == 'profile_version_conflict') {
        try {
          await store.remove(record);
          _rejected.add(record.operationId);
        } catch (_) {
          // Keep recovery until its durable removal succeeds.
        }
      }
      errors[record.operationId] = failure is DeletionException
          ? failure.toString()
          : const DeletionException('server_unavailable').toString();
    } finally {
      _running.remove(record.operationId);
      _notify();
    }
  }

  void dismiss(DeletionRecord record) {
    if (!finished(record)) return;
    _records.remove(record);
    _complete.remove(record.operationId);
    _rejected.remove(record.operationId);
    _confirmed.remove(record.operationId);
    errors.remove(record.operationId);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
