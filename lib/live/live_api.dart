import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import '../push/push_api.dart' show pushSessionId;
import 'chat_api.dart' show newChatOperationId;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../profile/profile_store.dart';
import '../profile/user_profile.dart';
import 'avatar_upload.dart';
import 'browser_storage.dart';
import 'invitation_controller.dart';
import 'member_capabilities.dart';
import '../platform/storage/profile_write_journal.dart';
import '../platform/storage/profile_write_journal_factory.dart';

class LiveApiException implements Exception {
  const LiveApiException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'invalid_invitation' =>
      'This invitation has expired or is no longer valid. Ask for a new QR or code.',
    'own_invitation' =>
      'This is your own invitation. Open another person’s QR or code to connect.',
    'invitation_required' => 'Enter a valid invitation code to sign in.',
    'membership_required' => 'Complete registration with an invitation first.',
    'invitation_account_mismatch' =>
      'Sign in with the Google account this invitation was sent to.',
    'sign_in_required' ||
    'session_revoked' => 'Please sign in again to continue.',
    'invalid_profile' =>
      'Check your name, photo, summary and offered skills, then try again.',
    'rate_limited' => 'Too many attempts. Wait a minute and try again.',
    'profile_upgrade_required' => 'Refresh this page to save your changes',
    'offering_limit_reached' => 'Invite 10 people to add more offered skills.',
    _ => 'Could not reach Paul. Check your connection and try again.',
  };
}

class MemberProfile {
  const MemberProfile({
    required this.id,
    required this.profile,
    required this.contactCount,
    this.avatarPath,
  });
  final String id;
  final UserProfile profile;
  final int contactCount;
  final String? avatarPath;

  factory MemberProfile.fromJson(Map<String, dynamic> value) => MemberProfile(
    id: value['id'] as String,
    profile: UserProfile(
      name: value['name'] as String,
      occupation: value['occupation'] as String,
      summary: value['summary'] as String,
      skills: List<String>.from(value['skills'] as List),
      searchingSkills: List<String>.from(value['searching_skills'] as List),
    ),
    contactCount: value['contact_count'] as int,
    avatarPath: value['avatar_path'] as String?,
  );
}

class MemberNetwork {
  const MemberNetwork({this.own, this.contacts = const []});
  final MemberProfile? own;
  final List<MemberProfile> contacts;
}

class LiveApi implements InvitationIssuer {
  LiveApi(this.client);
  final SupabaseClient client;

  Future<MemberCapabilities> capabilities() async {
    final userId = client.auth.currentUser?.id;
    final token = client.auth.currentSession?.accessToken;
    if (userId == null || token == null) {
      throw const LiveApiException('sign_in_required');
    }
    try {
      final response = await client.functions
          .invoke(
            'account',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': 'capabilities'},
          )
          .timeout(const Duration(seconds: 25));
      if (client.auth.currentUser?.id != userId) {
        throw const LiveApiException('sign_in_required');
      }
      return MemberCapabilities.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    } on FunctionException catch (error) {
      final details = error.details;
      throw LiveApiException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  Future<Map<String, dynamic>> call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    final identity = client.auth.currentUser?.id;
    final session =
        pushSessionId(client) ?? client.auth.currentSession?.accessToken;
    final token = client.auth.currentSession?.accessToken;
    try {
      final response = await client.functions
          .invoke(
            'invitations',
            headers: token == null ? null : {'Authorization': 'Bearer $token'},
            body: {'action': action, ...fields},
          )
          .timeout(const Duration(seconds: 25));
      if (client.auth.currentUser?.id != identity ||
          (pushSessionId(client) ?? client.auth.currentSession?.accessToken) !=
              session) {
        throw const LiveApiException('sign_in_required');
      }
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      final details = error.details;
      throw LiveApiException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<LiveInvitation> issue(String token) async {
    final owner = client.auth.currentUser?.id;
    final session = pushSessionId(client);
    if (owner == null || session == null) {
      throw const LiveApiException('sign_in_required');
    }
    final pendingKey = 'paul.invitation.issue.$owner.$session';
    final operationToken = readSessionValue(pendingKey) ?? token;
    writeSessionValue(pendingKey, operationToken);
    final elapsed = Stopwatch()..start();
    try {
      final data = await call('issue', {'token': operationToken});
      final expires = DateTime.parse(data['expires_at'] as String);
      final remaining =
          expires.difference(DateTime.parse(data['server_now'] as String)) -
          elapsed.elapsed;
      if (remaining <= Duration.zero) throw InvitationRenewalRequired();
      removeSessionValue(pendingKey);
      return LiveInvitation(
        id: data['id'] as String,
        token: operationToken,
        code: data['code'] as String,
        expiresAt: expires,
        lifetime: remaining,
      );
    } on LiveApiException catch (error) {
      if (error.code == 'invalid_invitation' ||
          error.code == 'invitation_collision') {
        removeSessionValue(pendingKey);
        throw InvitationRenewalRequired();
      }
      rethrow;
    }
  }

  @override
  Future<void> revoke(String id) async => call('revoke', {'id': id});

  Future<void> check(String credential) async =>
      call('check', {'credential': credential});

  Future<MemberNetwork> network() async {
    final data = await call('network');
    final own = data['profile'];
    return MemberNetwork(
      own: own is Map<String, dynamic> ? MemberProfile.fromJson(own) : null,
      contacts: (data['contacts'] as List)
          .map(
            (value) =>
                MemberProfile.fromJson(Map<String, dynamic>.from(value as Map)),
          )
          .toList(),
    );
  }

  Future<MemberProfile> member(String profileId) async {
    final userId = client.auth.currentUser?.id;
    final token = client.auth.currentSession?.accessToken;
    if (userId == null || token == null) {
      throw const LiveApiException('sign_in_required');
    }
    try {
      final response = await client.functions
          .invoke(
            'account',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': 'profile', 'profile_id': profileId},
          )
          .timeout(const Duration(seconds: 25));
      if (client.auth.currentUser?.id != userId) {
        throw const LiveApiException('sign_in_required');
      }
      final profile = (response.data as Map)['profile'];
      return MemberProfile.fromJson(Map<String, dynamic>.from(profile as Map));
    } on FunctionException catch (error) {
      final details = error.details;
      throw LiveApiException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  Future<Map<String, dynamic>> profilePayload(
    UserProfile draft,
    String userId,
  ) async {
    String? avatarPath;
    if (draft.photo != null) {
      try {
        avatarPath = await uploadAvatar(client, userId, draft.photo!);
      } on AuthException {
        throw const LiveApiException('sign_in_required');
      }
    }
    return {
      'name': draft.name,
      'occupation': draft.occupation,
      'summary': draft.summary,
      'skills': draft.skills,
      'searching_skills': draft.searchingSkills,
      'avatar_path': avatarPath,
    };
  }

  Future<void> redeem(String credential, {UserProfile? draft}) async {
    final user = client.auth.currentUser;
    final session = pushSessionId(client);
    if (user == null) throw const LiveApiException('sign_in_required');
    final key =
        'paul.registration.${user.id}.$session.${sha256.convert(utf8.encode(credential))}';
    Map<String, dynamic>? pending;
    if (draft != null) {
      final saved = readSessionValue(key);
      pending = saved == null
          ? {
              'owner': user.id,
              'session': session,
              'draft': draft.encode(),
              'avatar_path': draft.photo == null
                  ? null
                  : newAvatarUploadPath(user.id),
            }
          : Map<String, dynamic>.from(jsonDecode(saved) as Map);
      if (pending['owner'] != user.id || pending['session'] != session) {
        throw const LiveApiException('sign_in_required');
      }
      // Synchronous SQLite commit on mobile, before any remote mutation.
      writeSessionValue(key, jsonEncode(pending));
    }
    final preparation = await call('prepare', {'credential': credential});
    Map<String, dynamic>? payload;
    if (pending != null && preparation['admitted'] != true) {
      final submitted = UserProfile.decode(pending['draft'] as String);
      final path = pending['avatar_path'] as String?;
      if (submitted.photo != null && path != null) {
        try {
          await uploadAvatar(
            client,
            user.id,
            submitted.photo!,
            reservedPath: path,
          );
        } on AuthException {
          throw const LiveApiException('sign_in_required');
        }
      }
      payload = {
        'name': submitted.name,
        'occupation': submitted.occupation,
        'summary': submitted.summary,
        'skills': submitted.skills,
        'searching_skills': submitted.searchingSkills,
        'avatar_path': path,
      };
    }
    if (client.auth.currentUser?.id != user.id ||
        pushSessionId(client) != session) {
      throw const LiveApiException('sign_in_required');
    }
    await call('redeem', {'credential': credential, 'profile': ?payload});
    removeSessionValue(key);
  }

  Future<Uint8List?> photo(MemberProfile member) async {
    final path = member.avatarPath;
    return path == null ? null : client.storage.from('avatars').download(path);
  }
}

class SupabaseProfileStore implements ReconciledProfileStore {
  SupabaseProfileStore(
    this.api,
    this.userId, {
    MemberProfile? initialProfile,
    String? initialSession,
    ProfileWriteJournal? journal,
  }) : _journal = journal ?? createProfileWriteJournal(),
       _session =
           pushSessionId(api.client) ??
           api.client.auth.currentSession?.accessToken {
    if (initialProfile?.id == userId &&
        initialSession != null &&
        initialSession == _session) {
      _initialProfile = initialProfile;
    }
  }
  final LiveApi api;
  final String userId;
  final String? _session;
  MemberProfile? _initialProfile;
  Map<String, dynamic>? _base;
  UserProfile? _localBase;
  final ProfileWriteJournal _journal;
  PendingProfileWrite? _pending;
  bool _journalLoaded = false;
  Uint8List? _uploadedPhoto;
  String? _uploadedPath;

  void _checkSession() {
    if (api.client.auth.currentUser?.id != userId ||
        _session == null ||
        (pushSessionId(api.client) ??
                api.client.auth.currentSession?.accessToken) !=
            _session) {
      throw const LiveApiException('sign_in_required');
    }
  }

  Map<String, dynamic> _payload(MemberProfile own) => {
    'name': own.profile.name,
    'occupation': own.profile.occupation,
    'summary': own.profile.summary,
    'skills': own.profile.skills,
    'searching_skills': own.profile.searchingSkills,
    'avatar_path': own.avatarPath,
  };
  Future<UserProfile> _accept(
    MemberProfile own, {
    UserProfile? submitted,
    String? submittedPath,
  }) async {
    final photo = own.avatarPath == null
        ? null
        : own.avatarPath == submittedPath && submitted != null
        ? submitted.photo
        : own.avatarPath == _base?['avatar_path'] && _localBase != null
        ? _localBase!.photo
        : await api.photo(own);
    _checkSession();
    _base = _payload(own);
    return _localBase = own.profile.copyWith(
      photo: photo,
      clearPhoto: photo == null,
    );
  }

  Future<void> _restorePending() async {
    if (_journalLoaded) return;
    final saved = await _journal.read(userId, userId);
    _checkSession();
    if (saved != null &&
        (saved.actorId != userId || saved.profileId != userId)) {
      throw const LiveApiException('sign_in_required');
    }
    _pending = saved;
    if (saved != null) _initialProfile = null;
    _journalLoaded = true;
  }

  @override
  Future<UserProfile> read() async {
    _checkSession();
    await _restorePending();
    // Resolve an uncertain write before replacing the baseline used by its retry.
    if (_pending != null) await _sendPending();
    // Consume before any await, including a failed private photo download.
    final initial = _initialProfile;
    _initialProfile = null;
    final own = initial ?? (await api.network()).own;
    _checkSession();
    if (own == null) throw const LiveApiException('membership_required');
    return _accept(own);
  }

  Future<UserProfile> _sendPending() async {
    final pending = _pending!;
    _checkSession();
    try {
      if (pending.uploadRequired && !pending.uploaded) {
        await uploadAvatar(
          api.client,
          userId,
          pending.profile.photo!,
          reservedPath: pending.avatarPath,
        );
        _checkSession();
        _uploadedPhoto = Uint8List.fromList(pending.profile.photo!);
        _uploadedPath = pending.avatarPath;
        await _journal.markUploaded(pending);
        _checkSession();
        _pending = PendingProfileWrite.restore(
          operationId: pending.operationId,
          originSessionId: pending.originSessionId,
          uploaded: true,
          payload: pending.payload,
        );
      }
      final result = await api.call('merge_profile', {
        'operation_id': pending.operationId,
        'base': pending.base,
        'changes': pending.changes,
      });
      _checkSession();
      // Keep the receipt until the response/photo is accepted; a retry only reads the receipt.
      final own = MemberProfile.fromJson(
        Map<String, dynamic>.from(result['profile'] as Map),
      );
      final saved = await _accept(
        own,
        submitted: pending.profile,
        submittedPath: pending.avatarPath,
      );
      await _journal.complete(pending);
      _checkSession();
      _pending = null;
      return saved;
    } on LiveApiException catch (error) {
      if (error.code == 'profile_conflict') {
        await _journal.complete(pending);
        _checkSession();
        _pending = null;
        final own = (await api.network()).own;
        _checkSession();
        if (own == null) throw const LiveApiException('membership_required');
        throw ProfileConflictException(await _accept(own));
      }
      if (error.code == 'offering_limit_reached') {
        await _journal.complete(pending);
        _checkSession();
        _pending = null;
      }
      if (error.code == 'invalid_profile' || error.code == 'avatar_retired') {
        await _journal.complete(pending);
        _checkSession();
        _pending = null;
        _uploadedPath = null;
        _uploadedPhoto = null;
      }
      rethrow;
    }
  }

  @override
  Future<UserProfile> save(UserProfile profile) async {
    _checkSession();
    await _restorePending();
    if (_base == null || _localBase == null) {
      throw StateError('Read the profile before saving.');
    }
    if (_pending case final pending?) {
      final saved = await _sendPending();
      if (profile.changesFrom(pending.profile).isEmpty) return saved;
      profile = profile.rebase(pending.profile, saved);
    }
    final dirty = profile.changesFrom(_localBase!);
    if (dirty.isEmpty) return _localBase!;
    var path = _base!['avatar_path'] as String?;
    var uploadRequired = false;
    if (dirty.contains('photo')) {
      if (profile.photo == null) {
        path = null;
      } else if (profileValueEqual(profile.photo, _uploadedPhoto) &&
          _uploadedPath != null) {
        path = _uploadedPath;
      } else {
        path = newAvatarUploadPath(userId);
        uploadRequired = true;
      }
    }
    final values = {...profile.editableFields}..remove('photo');
    final changes = <String, dynamic>{
      for (final key in dirty.where((k) => k != 'photo')) key: values[key],
      if (dirty.contains('photo')) 'avatar_path': path,
    };
    _pending = await _journal.prepare(
      PendingProfileWrite(
        actorId: userId,
        profileId: userId,
        operationId: newChatOperationId(),
        originSessionId: _session,
        base: Map.of(_base!),
        changes: changes,
        profile: profile,
        avatarPath: path,
        uploadRequired: uploadRequired,
      ),
    );
    _checkSession();
    return _sendPending();
  }

  @override
  Future<void> write(UserProfile profile) async {
    await save(profile);
  }

  @override
  Future<void> clear() async => throw UnsupportedError(
    'Account deletion requires the server account workflow.',
  );
}
