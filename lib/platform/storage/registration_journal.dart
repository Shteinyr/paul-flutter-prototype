import '../../profile/user_profile.dart';

class PendingRegistration {
  const PendingRegistration({
    required this.userId,
    required this.sessionId,
    required this.operationId,
    required this.credential,
    required this.profile,
    this.avatarPath,
    this.uploaded = false,
  });
  final String userId;
  final String sessionId;
  final String operationId;
  final String credential;
  final UserProfile profile;
  final String? avatarPath;
  final bool uploaded;

  Map<String, dynamic> get payload => {
    'version': 1,
    'user_id': userId,
    'session_id': sessionId,
    'credential': credential,
    'profile': profile.encode(),
    'avatar_path': avatarPath,
  };

  Map<String, dynamic> get profilePayload => {
    ...profile.editableFields..remove('photo'),
    'avatar_path': avatarPath,
  };

  factory PendingRegistration.restore({
    required String operationId,
    required Map<String, dynamic> payload,
    required bool uploaded,
  }) {
    if (payload['version'] != 1 ||
        payload['user_id'] is! String ||
        payload['session_id'] is! String ||
        payload['credential'] is! String ||
        payload['profile'] is! String ||
        (payload['avatar_path'] != null && payload['avatar_path'] is! String)) {
      throw const FormatException('Invalid saved registration.');
    }
    return PendingRegistration(
      userId: payload['user_id'] as String,
      sessionId: payload['session_id'] as String,
      operationId: operationId,
      credential: payload['credential'] as String,
      profile: UserProfile.decode(payload['profile'] as String),
      avatarPath: payload['avatar_path'] as String?,
      uploaded: uploaded,
    );
  }
}

abstract interface class RegistrationJournal {
  Future<PendingRegistration?> read(String userId, String sessionId);
  Future<PendingRegistration> prepare(PendingRegistration candidate);
  Future<void> markUploaded(PendingRegistration pending);
  Future<void> complete(PendingRegistration pending);
}

/// Authorize must recheck the invite on the server (or confirm the same
/// already-admitted session). A stored credential is never authorization.
class RegistrationRecovery {
  const RegistrationRecovery(this.journal);
  final RegistrationJournal journal;

  Future<T> execute<T>(
    PendingRegistration candidate, {
    required String? Function() currentUserId,
    required String? Function() currentSessionId,
    required Future<void> Function(PendingRegistration) authorize,
    required Future<void> Function(PendingRegistration) upload,
    required Future<T> Function(PendingRegistration) redeem,
  }) async {
    void check() {
      if (currentUserId() != candidate.userId ||
          currentSessionId() != candidate.sessionId) {
        throw StateError('Registration belongs to another account session.');
      }
    }

    check();
    var pending = await journal.prepare(candidate);
    check();
    if (pending.userId != candidate.userId ||
        pending.sessionId != candidate.sessionId) {
      throw StateError('Registration belongs to another account session.');
    }
    await authorize(pending);
    check();
    if (pending.profile.photo != null && !pending.uploaded) {
      if (pending.avatarPath == null) {
        throw StateError('Reserve the avatar path before registration.');
      }
      await upload(pending);
      check();
      await journal.markUploaded(pending);
      pending = PendingRegistration.restore(
        operationId: pending.operationId,
        payload: pending.payload,
        uploaded: true,
      );
      check();
    }
    final result = await redeem(pending);
    check();
    await journal.complete(pending);
    return result;
  }
}
