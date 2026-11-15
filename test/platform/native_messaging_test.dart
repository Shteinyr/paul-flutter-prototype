import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/platform/notifications/native_messaging.dart';
import 'package:paul_demo/platform/notifications/native_push_store.dart';
import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';

const actor = '15000000-0000-4000-8000-000000000001';
const other = '15000000-0000-4000-8000-000000000002';
const session = '15100000-0000-4000-8000-000000000001';
const laterSession = '15100000-0000-4000-8000-000000000002';
const bindingId = '15200000-0000-4000-8000-000000000001';

class FirebasePort extends Fake implements FirebaseMessaging {
  final registrations = StreamController<String>.broadcast(sync: true);
  bool fail = false;
  int unregistered = 0;
  @override
  Stream<String> get onRegistered => registrations.stream;
  @override
  Future<void> register({
    String? vapidKey,
    String? serviceWorkerScriptPath,
  }) async {
    if (fail) throw StateError('registration failed');
    registrations.add('fid-installation-id-123');
  }

  @override
  Future<void> unregister() async {
    unregistered++;
  }
}

void main() {
  test(
    'FCM adapter listens before register and returns FID on repeated registration',
    () async {
      final firebase = FirebasePort();
      addTearDown(firebase.registrations.close);
      final port = FirebaseMessagingPort(firebase);
      expect(await port.token(), 'fid-installation-id-123');
      expect(await port.token(), 'fid-installation-id-123');
      expect(firebase.registrations.hasListener, isFalse);
      final changed = port.tokenChanges.first;
      firebase.registrations.add('rotated-installation-id');
      expect(await changed, 'rotated-installation-id');
      await port.deleteToken();
      expect(firebase.unregistered, 1);
    },
  );
  test('failed registration cancels the FID listener', () async {
    final firebase = FirebasePort()..fail = true;
    addTearDown(firebase.registrations.close);
    await expectLater(
      FirebaseMessagingPort(firebase).token(),
      throwsStateError,
    );
    expect(firebase.registrations.hasListener, isFalse);
  });
  test(
    'SQLite binding survives restart, stays account/session scoped and removes only its owner',
    () async {
      final parent = Directory('.dart_tool')..createSync(recursive: true);
      final directory = parent.createTempSync('native-push-store-');
      final path = '${directory.absolute.path}/journal.sqlite';
      var db = SqliteJournalStore.open(path);
      addTearDown(() {
        db.close();
        directory.deleteSync(recursive: true);
      });
      var store = SqliteNativePushStore(db);
      await store.write(NativePushBinding(actor, session, bindingId, 'a' * 64));
      await store.write(NativePushBinding(other, session, bindingId, 'b' * 64));
      await store.setRetirementPending(true);
      db.close();
      db = SqliteJournalStore.open(path);
      store = SqliteNativePushStore(db);
      expect(await store.retirementPending(), isTrue);
      expect((await store.read(actor, session))?.tokenDigest, 'a' * 64);
      expect((await store.read(other, session))?.tokenDigest, 'b' * 64);
      await store.setRetirementPending(false);
      expect(await store.retirementPending(), isFalse);
      expect(await store.read(actor, laterSession), isNull);
      await store.remove(actor, session);
      expect(await store.read(actor, session), isNull);
      expect((await store.read(other, session))?.tokenDigest, 'b' * 64);
    },
  );
}
