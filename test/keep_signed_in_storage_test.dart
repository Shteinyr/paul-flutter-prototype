import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/keep_signed_in_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class Disk extends LocalStorage {
  String? value;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => value != null;
  @override
  Future<String?> accessToken() async => value;
  @override
  Future<void> persistSession(String persistSessionString) async {
    value = persistSessionString;
  }

  @override
  Future<void> removePersistedSession() async {
    value = null;
  }
}

void main() {
  test(
    'kept session restores through a new app process without changing its storage key',
    () async {
      final disk = Disk();
      final first = KeepSignedInStorage(disk, remember: () => true);
      await first.initialize();
      await first.persistSession('admitted-session');
      final reopened = KeepSignedInStorage(disk, remember: () => true);
      await reopened.initialize();
      expect(await reopened.accessToken(), 'admitted-session');
    },
  );
  test(
    'opting out keeps this run alive and restores no session on restart',
    () async {
      var remember = true;
      final disk = Disk();
      final first = KeepSignedInStorage(disk, remember: () => remember);
      await first.initialize();
      await first.persistSession('old');
      remember = false;
      await first.persistSession('current');
      expect(await first.accessToken(), 'current');
      expect(disk.value, isNull);
      final reopened = KeepSignedInStorage(disk, remember: () => false);
      await reopened.initialize();
      expect(await reopened.hasAccessToken(), false);
      expect(await reopened.accessToken(), isNull);
    },
  );
}
