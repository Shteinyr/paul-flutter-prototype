import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:paul_demo/platform/storage/native_session_storage.dart';
import 'package:paul_demo/platform/storage/profile_write_journal.dart';
import 'package:paul_demo/platform/storage/sqlite_adapters.dart';
import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:paul_demo/platform/storage/registration_journal.dart';

const actor = '15000000-0000-4000-8000-000000000001';
const other = '15000000-0000-4000-8000-000000000002';
const operation = '15000000-0000-4000-8000-000000000003';
const laterOperation = '15000000-0000-4000-8000-000000000004';

PendingProfileWrite write({
  String id = operation,
  String name = 'Saved name',
}) => PendingProfileWrite(
  actorId: actor,
  profileId: actor,
  operationId: id,
  originSessionId: '15000000-0000-4000-8000-000000000005',
  base: const {'name': 'Before'},
  changes: {'name': name},
  profile: UserProfile(name: name, photo: Uint8List.fromList([1, 2, 3])),
  avatarPath: '$actor/${'a' * 64}.png',
  uploadRequired: true,
);

void main() {
  late Directory directory;
  late String path;
  late SqliteJournalStore store;
  setUp(() {
    final parent = Directory('.dart_tool')..createSync(recursive: true);
    directory = parent.createTempSync('journal-test-');
    path = '${directory.absolute.path}/journal.sqlite';
    store = SqliteJournalStore.open(path);
  });
  tearDown(() {
    NativeSessionStorage.unbind();
    store.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'account values survive reopen and cannot leak into another account',
    () {
      final a = NativeSessionStorage(store, accountStorageScope(actor));
      final b = NativeSessionStorage(store, accountStorageScope(other));
      a.write('pending-invite', 'private-to-actor');
      b.write('pending-invite', 'private-to-other');
      store.close();
      store = SqliteJournalStore.open(path);
      expect(
        NativeSessionStorage(
          store,
          accountStorageScope(actor),
        ).read('pending-invite'),
        'private-to-actor',
      );
      expect(
        NativeSessionStorage(
          store,
          accountStorageScope(other),
        ).read('pending-invite'),
        'private-to-other',
      );
      store.deleteScope(accountStorageScope(actor));
      expect(
        NativeSessionStorage(
          store,
          accountStorageScope(actor),
        ).read('pending-invite'),
        isNull,
      );
      expect(
        NativeSessionStorage(
          store,
          accountStorageScope(other),
        ).read('pending-invite'),
        'private-to-other',
      );
    },
  );

  test(
    'Chat, Hiring draft and close receipts survive restart under their owner',
    () async {
      var adapter = SqliteChatStateStore(store, accountId: actor);
      await adapter.write(actor, 'chat snapshot');
      await adapter.write('community.$actor', 'Hiring draft');
      await adapter.write('community.close.$actor.request', operation);
      store.close();
      store = SqliteJournalStore.open(path);
      adapter = SqliteChatStateStore(store, accountId: actor);
      expect(await adapter.read(actor), 'chat snapshot');
      expect(await adapter.read('community.$actor'), 'Hiring draft');
      expect(await adapter.read('community.close.$actor.request'), operation);
      await expectLater(adapter.write(other, 'wrong owner'), throwsStateError);
      await expectLater(adapter.read(other), throwsStateError);
      expect(
        await SqliteChatStateStore(store, accountId: other).read(other),
        isNull,
      );
    },
  );

  test('two connections adopt the first committed operation ID', () async {
    final second = SqliteJournalStore.open(path);
    try {
      final first = await SqliteProfileWriteJournal(store).prepare(write());
      final retry = await SqliteProfileWriteJournal(
        second,
      ).prepare(write(id: laterOperation));
      expect(first.operationId, operation);
      expect(retry.operationId, operation);
    } finally {
      second.close();
    }
  });

  test(
    'conflicting payload rolls back without replacing the original operation',
    () async {
      final journal = SqliteProfileWriteJournal(store);
      await journal.prepare(write());
      await expectLater(
        journal.prepare(write(id: laterOperation, name: 'Different')),
        throwsA(isA<PendingJournalConflict>()),
      );
      final pending = await journal.read(actor, actor);
      expect(pending!.operationId, operation);
      expect(pending.profile.name, 'Saved name');
    },
  );

  test(
    'profile snapshot and confirmed avatar phase survive database close',
    () async {
      var journal = SqliteProfileWriteJournal(store);
      final pending = await journal.prepare(write());
      await journal.markUploaded(pending);
      store.close();
      store = SqliteJournalStore.open(path);
      journal = SqliteProfileWriteJournal(store);
      final restored = (await journal.read(actor, actor))!;
      expect(restored.uploaded, isTrue);
      expect(restored.uploadRequired, isTrue);
      expect(restored.avatarPath, write().avatarPath);
      expect(restored.profile.photo, [1, 2, 3]);
      expect(restored.operationId, operation);
      expect(await journal.read(other, actor), isNull);
    },
  );

  test('late acknowledgement cannot erase a newer pending operation', () async {
    final journal = SqliteProfileWriteJournal(store);
    final first = await journal.prepare(write());
    await journal.complete(first);
    await journal.prepare(write(id: laterOperation, name: 'Later'));
    await journal.complete(first);
    expect((await journal.read(actor, actor))!.operationId, laterOperation);
  });

  test(
    'lost ACK recovers the same remote receipt after process state is lost',
    () async {
      final receipts = <String, String>{};
      var mutations = 0;
      var journal = SqliteProfileWriteJournal(store);
      await expectLater(
        ProfileWriteRecovery(journal).execute(
          write(),
          isCurrent: () => true,
          sendAndAccept: (pending) async {
            final observer = SqliteJournalStore.open(path);
            try {
              expect(
                (await SqliteProfileWriteJournal(
                  observer,
                ).read(actor, actor))!.operationId,
                pending.operationId,
              );
            } finally {
              observer.close();
            }
            receipts.putIfAbsent(pending.operationId, () {
              mutations++;
              return 'confirmed';
            });
            throw StateError('Response lost after server commit');
          },
        ),
        throwsStateError,
      );
      store.close();
      store = SqliteJournalStore.open(path);
      journal = SqliteProfileWriteJournal(store);
      final result = await ProfileWriteRecovery(journal).execute(
        write(id: laterOperation),
        isCurrent: () => true,
        sendAndAccept: (pending) async =>
            receipts.putIfAbsent(pending.operationId, () {
              mutations++;
              return 'duplicate';
            }),
      );
      expect(result, 'confirmed');
      expect(mutations, 1);
      expect(await journal.read(actor, actor), isNull);
    },
  );

  test(
    'identity change after the request retains recovery for the original account',
    () async {
      var current = true;
      final journal = SqliteProfileWriteJournal(store);
      await expectLater(
        ProfileWriteRecovery(journal).execute(
          write(),
          isCurrent: () => current,
          sendAndAccept: (_) async {
            current = false;
            return 'server acknowledged';
          },
        ),
        throwsStateError,
      );
      expect((await journal.read(actor, actor))!.operationId, operation);
      expect(await journal.read(other, other), isNull);
    },
  );

  test('database error prevents any remote mutation', () async {
    final journal = SqliteProfileWriteJournal(store);
    store.close();
    var calls = 0;
    await expectLater(
      ProfileWriteRecovery(journal).execute(
        write(),
        isCurrent: () => true,
        sendAndAccept: (_) async {
          calls++;
          return 'must not happen';
        },
      ),
      throwsStateError,
    );
    expect(calls, 0);
  });

  test('unsupported schema fails without deleting existing data', () {
    final alternate = '${directory.absolute.path}/future.sqlite';
    final db = sqlite3.open(alternate);
    db.execute('CREATE TABLE preserved(value TEXT)');
    db.execute("INSERT INTO preserved VALUES ('keep')");
    db.execute('PRAGMA user_version = 99');
    db.close();
    expect(() => SqliteJournalStore.open(alternate), throwsStateError);
    final check = sqlite3.open(alternate);
    expect(check.select('SELECT value FROM preserved').single['value'], 'keep');
    check.close();
  });

  test(
    'committed WAL survives a killed writer process without graceful close',
    () async {
      store.close();
      final dart =
          '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart';
      final child = await Process.start(dart, [
        'run',
        'test/support/native_journal_process.dart',
        path,
      ]);
      final errors = child.stderr.transform(utf8.decoder).join();
      try {
        final line = await child.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 60));
        expect(line, 'committed');
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        store = SqliteJournalStore.open(path);
        expect(store.read('account:$actor', 'process-proof'), 'durable');
        expect(
          store.pending('account:$actor', 'profile', actor)!.operationId,
          operation,
        );
      } finally {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
        final diagnostic = await errors;
        expect(
          diagnostic.replaceAll('Running build hooks...', '').trim(),
          isEmpty,
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
  test(
    'registration recovery pins session and rechecks authorization before any upload',
    () async {
      const session = '15000000-0000-4000-8000-000000000005';
      final journal = SqliteRegistrationJournal(store);
      final candidate = PendingRegistration(
        userId: actor,
        sessionId: session,
        operationId: operation,
        credential: '12345678',
        profile: write().profile,
        avatarPath: write().avatarPath,
      );
      var uploads = 0;
      var redemptions = 0;
      await expectLater(
        RegistrationRecovery(journal).execute(
          candidate,
          currentUserId: () => actor,
          currentSessionId: () => session,
          authorize: (_) async => throw StateError('expired invite'),
          upload: (_) async {
            uploads++;
          },
          redeem: (_) async {
            redemptions++;
          },
        ),
        throwsStateError,
      );
      expect(uploads, 0);
      expect(redemptions, 0);
      store.close();
      store = SqliteJournalStore.open(path);
      final restored = SqliteRegistrationJournal(store);
      expect(await restored.read(actor, 'different-session'), isNull);
      final pending = (await restored.read(actor, session))!;
      expect(pending.operationId, operation);
      await expectLater(
        RegistrationRecovery(restored).execute(
          pending,
          currentUserId: () => actor,
          currentSessionId: () => 'different-session',
          authorize: (_) async {},
          upload: (_) async {
            uploads++;
          },
          redeem: (_) async {
            redemptions++;
          },
        ),
        throwsStateError,
      );
      expect(uploads, 0);
      final result = await RegistrationRecovery(restored).execute(
        pending,
        currentUserId: () => actor,
        currentSessionId: () => session,
        authorize: (_) async {},
        upload: (value) async {
          expect(
            (await restored.read(actor, session))!.avatarPath,
            value.avatarPath,
          );
          uploads++;
        },
        redeem: (value) async {
          expect(value.profilePayload.containsKey('photo'), isFalse);
          expect(value.profilePayload['avatar_path'], value.avatarPath);
          redemptions++;
          return 'registered';
        },
      );
      expect(result, 'registered');
      expect(uploads, 1);
      expect(redemptions, 1);
      expect(await restored.read(actor, session), isNull);
    },
  );
}
