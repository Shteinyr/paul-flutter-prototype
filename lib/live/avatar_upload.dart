import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Each attempt owns an immutable version, including after a failed finalization.
/// A retired path is never reused by a late upload or cleanup request.
Future<String> uploadAvatar(
  SupabaseClient client,
  String userId,
  Uint8List photo,
) async {
  void checkIdentity() {
    if (client.auth.currentUser?.id != userId) {
      throw const AuthException('sign_in_required');
    }
  }

  checkIdentity();
  final random = Random.secure();
  final version = List.generate(
    32,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final path = '$userId/$version.png';
  await client.rpc('avatar_upload_begin', params: {'p_path': path});
  checkIdentity();
  await client.storage
      .from('avatars')
      .uploadBinary(
        path,
        photo,
        fileOptions: const FileOptions(contentType: 'image/png', upsert: false),
      );
  checkIdentity();
  return path;
}
