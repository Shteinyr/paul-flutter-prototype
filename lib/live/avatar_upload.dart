import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

import '../push/push_api.dart' show pushSessionId;

/// Each attempt owns an immutable version, including after a failed finalization.
/// A retired path is never reused by a late upload or cleanup request.
Future<String> uploadAvatar(
  SupabaseClient client,
  String userId,
  Uint8List photo, {
  String? reservedPath,
}) async {
  final session =
      pushSessionId(client) ?? client.auth.currentSession?.accessToken;
  void checkIdentity() {
    if (session == null ||
        client.auth.currentUser?.id != userId ||
        (pushSessionId(client) ?? client.auth.currentSession?.accessToken) !=
            session) {
      throw const AuthException('sign_in_required');
    }
  }

  checkIdentity();
  final path = reservedPath ?? newAvatarUploadPath(userId);
  if (!RegExp(
    '^${RegExp.escape(userId)}/[a-f0-9]{64}[.]png'
    r'$',
  ).hasMatch(path)) {
    throw ArgumentError('Avatar path does not belong to this account.');
  }
  await client.rpc('avatar_upload_begin', params: {'p_path': path});
  checkIdentity();
  try {
    await client.storage
        .from('avatars')
        .uploadBinary(
          path,
          photo,
          fileOptions: const FileOptions(
            contentType: 'image/png',
            upsert: false,
          ),
        );
  } on StorageException catch (error) {
    // A lost upload ACK can leave the immutable object in Storage. Confirm the
    // exact bytes before accepting a duplicate; never overwrite another object.
    if (reservedPath == null ||
        (error.statusCode != '409' && error.error != 'Duplicate')) {
      rethrow;
    }
    checkIdentity();
    final existing = await client.storage.from('avatars').download(path);
    checkIdentity();
    if (!listEquals(existing, photo)) {
      throw StateError('The pending avatar content does not match.');
    }
  }
  checkIdentity();
  return path;
}

String newAvatarUploadPath(String userId) {
  final random = Random.secure();
  final version = List.generate(
    32,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '$userId/$version.png';
}
