import 'dart:convert';

import '../../profile/user_profile.dart';

/// Persist before avatar upload or merge_profile. Reuse the same avatar path
/// and operation ID when recovering, including an unknown remote outcome.
class PendingProfileWrite {
  const PendingProfileWrite({
    required this.actorId,
    required this.profileId,
    required this.operationId,
    required this.base,
    required this.changes,
    required this.profile,
    this.originSessionId,
    this.avatarPath,
    this.uploadRequired = false,
    this.uploaded = false,
  });
  final String actorId;
  final String profileId;
  final String operationId;
  final String? originSessionId;
  final Map<String, dynamic> base;
  final Map<String, dynamic> changes;
  final UserProfile profile;
  final String? avatarPath;
  final bool uploadRequired;
  final bool uploaded;

  Map<String, dynamic> get payload => {
    'version': 1,
    'actor_id': actorId,
    'profile_id': profileId,
    'base': base,
    'changes': changes,
    'profile': profile.encode(),
    'avatar_path': avatarPath,
    'upload_required': uploadRequired,
  };

  factory PendingProfileWrite.restore({
    required String operationId,
    required String? originSessionId,
    required bool uploaded,
    required Map<String, dynamic> payload,
  }) {
    if (payload['version'] != 1 ||
        payload['actor_id'] is! String ||
        payload['profile_id'] is! String ||
        payload['base'] is! Map ||
        payload['changes'] is! Map ||
        payload['profile'] is! String ||
        payload['upload_required'] is! bool ||
        (payload['avatar_path'] != null && payload['avatar_path'] is! String)) {
      throw const FormatException('Invalid saved profile operation.');
    }
    return PendingProfileWrite(
      actorId: payload['actor_id'] as String,
      profileId: payload['profile_id'] as String,
      operationId: operationId,
      originSessionId: originSessionId,
      base: Map<String, dynamic>.from(payload['base'] as Map),
      changes: Map<String, dynamic>.from(payload['changes'] as Map),
      profile: UserProfile.decode(payload['profile'] as String),
      avatarPath: payload['avatar_path'] as String?,
      uploadRequired: payload['upload_required'] as bool,
      uploaded: uploaded,
    );
  }

  String encode() => jsonEncode({
    ...payload,
    'operation_id': operationId,
    'origin_session_id': originSessionId,
    'uploaded': uploaded,
  });
}

abstract interface class ProfileWriteJournal {
  Future<PendingProfileWrite?> read(String actorId, String profileId);
  Future<PendingProfileWrite> prepare(PendingProfileWrite candidate);
  Future<void> markUploaded(PendingProfileWrite pending);
  Future<void> complete(PendingProfileWrite pending);
}

/// The callback includes local acceptance of the response. A lost ACK, failed
/// photo read or changed identity retains the journal for the next process.
class ProfileWriteRecovery {
  const ProfileWriteRecovery(this.journal);
  final ProfileWriteJournal journal;

  Future<T> execute<T>(
    PendingProfileWrite candidate, {
    required bool Function() isCurrent,
    required Future<T> Function(PendingProfileWrite) sendAndAccept,
  }) async {
    if (!isCurrent()) throw StateError('Account session changed.');
    final pending = await journal.prepare(candidate);
    if (pending.actorId != candidate.actorId ||
        pending.profileId != candidate.profileId) {
      throw StateError('Recover with the original account.');
    }
    if (!isCurrent()) throw StateError('Account session changed.');
    final result = await sendAndAccept(pending);
    if (!isCurrent()) throw StateError('Account session changed.');
    await journal.complete(pending);
    return result;
  }
}
