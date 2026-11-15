import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/admin/managed_profile_editor.dart';
import 'package:paul_demo/admin/managed_profile_write_journal.dart';
import 'package:paul_demo/admin/operator_inbox_view.dart';
import 'package:paul_demo/live/browser_storage.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/platform/storage/account_value_store.dart';
import 'package:paul_demo/platform/storage/native_session_storage.dart';
import 'package:paul_demo/platform/storage/platform_storage.dart';
import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:paul_demo/photo_selection_journal.dart';

const profile = ManagedProfile(
  id: 'managed',
  name: 'Before',
  canManage: true,
  canReply: true,
  summary: 'Summary',
  skills: ['Design'],
  updatedAt: '2026-11-10T00:00:00Z',
);

class Repository implements AdminRepository {
  @override
  String userId = 'actor';
  ManagedProfile remote = profile;
  Object? failure;
  bool photoFails = false;
  final commands = <String>[];
  @override
  Future<AdminAccess> context() async => AdminAccess('admin', [remote]);
  @override
  Future<Uint8List?> photo(ManagedProfile profile) async {
    if (photoFails) throw StateError('Photo unavailable');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<void> command(Map<String, dynamic> fields) async {
    commands.add(jsonEncode(fields));
    if (failure != null) throw failure!;
  }

  @override
  ChatRepository operatorFor(String id) => throw UnimplementedError();
}

void main() {
  late Directory directory;
  late SqliteJournalStore db;
  String getPath() => '${directory.path}/test.sqlite';
  void reopen() {
    db.close();
    db = SqliteJournalStore.open(getPath());
    NativeSessionStorage.install(db, scope: 'installation');
  }

  setUp(() {
    directory = Directory('.dart_tool').createTempSync('managed-recovery-');
    db = SqliteJournalStore.open(getPath());
    NativeSessionStorage.install(db, scope: 'installation');
  });
  tearDown(() {
    NativeSessionStorage.unbind();
    db.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'managed create reservation and photo survive reopen; stale ACK is CAS fenced',
    () {
      final first = ManagedProfileWriteJournal('actor', null)..load();
      final draft = UserProfile(
        name: 'New',
        photo: Uint8List.fromList([1, 2, 3]),
      );
      first.saveDraft(
        draft,
        base: UserProfile.empty,
        version: null,
        avatarPath: null,
      );
      final command = first.prepare({
        'client_operation_id': 'original',
        'create': true,
        'photo_base64': base64Encode(draft.photo!),
      });
      reopen();
      final restored = ManagedProfileWriteJournal('actor', null)..load();
      expect(restored.pending, command);
      expect(restored.draft!.photo, [1, 2, 3]);
      expect(
        (ManagedProfileWriteJournal('actor', 'different')..load()).pending,
        isNull,
      );
      expect(
        (ManagedProfileWriteJournal('other', null)..load()).pending,
        isNull,
      );
      final stale = ManagedProfileWriteJournal('actor', null)..load();
      restored.complete('original');
      restored.saveDraft(
        draft,
        base: UserProfile.empty,
        version: null,
        avatarPath: null,
      );
      restored.prepare({'client_operation_id': 'newer', 'create': true});
      expect(
        () => stale.complete('original'),
        throwsA(isA<ManagedProfileDraftChanged>()),
      );
      expect(
        (ManagedProfileWriteJournal(
          'actor',
          null,
        )..load()).pending!['client_operation_id'],
        'newer',
      );
    },
  );

  test(
    'operator migration and account deletion erase only the matching actor',
    () async {
      const legacy = 'paul.live.chat.state.v1.admin.actor.managed';
      writeSessionValue(legacy, 'private chat');
      writeSessionValue(
        'paul.live.chat.state.v1.admin.other.managed',
        'other chat',
      );
      writeSessionValue(
        'paul.registration.actor.session.digest',
        'photo draft',
      );
      writeSessionValue('paul.invitation.issue.actor.session', 'invite');
      writeSessionValue('paul.registration.actor-two.session.digest', 'keep');
      final operator = OperatorChatStateStore('managed');
      expect(await operator.read('actor'), 'private chat');
      expect(readSessionValue(legacy), isNull);
      reopen();
      expect(await operator.read('actor'), 'private chat');
      expect(AccountValueStore('other').read('operator.chat.managed'), isNull);
      deleteAccountStorage('actor');
      expect(await operator.read('actor'), isNull);
      expect(
        readSessionValue('paul.registration.actor.session.digest'),
        isNull,
      );
      expect(readSessionValue('paul.invitation.issue.actor.session'), isNull);
      expect(
        readSessionValue('paul.registration.actor-two.session.digest'),
        'keep',
      );
      expect(await operator.read('other'), 'other chat');
    },
  );

  test(
    'account deletion retires late journal writers across database reopen',
    () async {
      final stale = AccountValueStore('actor');
      stale.write('draft', 'private');
      deleteAccountStorage('actor');
      expect(() => stale.write('draft', 'late'), throwsStateError);
      expect(() => stale.compareAndSwap('new', null, 'late'), throwsStateError);
      expect(
        () =>
            writeSessionValue('paul.registration.actor.session.digest', 'late'),
        throwsStateError,
      );
      await expectLater(
        OperatorChatStateStore('managed').write('actor', 'late message'),
        throwsStateError,
      );
      reopen();
      expect(db.isAccountDeleted('actor'), isTrue);
      expect(
        () => db.prepare(
          JournalOperation(
            scope: 'account:actor',
            kind: 'profile',
            target: 'managed',
            operationId: 'late',
            payload: const {},
          ),
        ),
        throwsStateError,
      );
      expect(db.read('account:actor', 'draft'), isNull);
      AccountValueStore('other').write('draft', 'allowed');
      expect(AccountValueStore('other').read('draft'), 'allowed');
    },
  );

  for (final owner in ['actor', 'other']) {
    for (final destination in PhotoDestination.values) {
      test(
        'account purge preserves unrelated global photo $owner $destination',
        () {
          final journal = PhotoSelectionJournal(
            read: () => db.read('installation', 'photo.selection.v1'),
            write: (value) =>
                db.write('installation', 'photo.selection.v1', value),
            remove: () => db.remove('installation', 'photo.selection.v1'),
          );
          journal.prepare(
            PhotoSelectionIntent(
              ownerId: owner,
              destination: destination,
              targetId: 'managed',
              operationId: 'selected',
            ),
          );
          deleteAccountStorage('actor');
          expect(
            journal.read() == null,
            owner == 'actor' && destination == PhotoDestination.profile,
          );
        },
      );
    }
  }

  Future<void> open(
    WidgetTester tester,
    Repository repository, {
    bool create = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ManagedProfileEditor(
          repository: repository,
          profile: create ? null : repository.remote,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'lost managed save ACK recovers exact command after process storage reopen',
    (tester) async {
      final repo = Repository()..failure = TimeoutException('lost ACK');
      await open(tester, repo);
      await tester.enterText(find.byKey(const Key('name-field')), 'Local edit');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.commands, hasLength(1));
      expect(find.text('Retry save'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      reopen();
      repo.photoFails = true; // Recovery cannot depend on a photo download.
      repo.failure = null;
      await open(tester, repo);
      expect(find.text('Local edit'), findsOneWidget);
      expect(find.text('Retry save'), findsOneWidget);
      await tester.tap(find.text('Retry save'));
      await tester.pumpAndSettle();
      expect(repo.commands, hasLength(2));
      expect(repo.commands[1], repo.commands[0]);
      expect(
        (ManagedProfileWriteJournal('actor', 'managed')..load()).pending,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'definitive validation failure retains editable draft with a new corrected operation',
    (tester) async {
      final repo = Repository()
        ..failure = const AdminException('invalid_profile');
      await open(tester, repo);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Retry save'), findsNothing);
      await tester.enterText(find.byKey(const Key('name-field')), 'Corrected');
      repo.failure = null;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repo.commands, hasLength(2));
      final first = jsonDecode(repo.commands[0]) as Map,
          last = jsonDecode(repo.commands[1]) as Map;
      expect(last['client_operation_id'], isNot(first['client_operation_id']));
      expect(last['profile']['name'], 'Corrected');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reopened conflicting draft asks before overwriting another device',
    (tester) async {
      final repo = Repository()
        ..failure = const AdminException('profile_version_conflict');
      await open(tester, repo);
      await tester.enterText(find.byKey(const Key('name-field')), 'Mine');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      reopen();
      repo.remote = const ManagedProfile(
        id: 'managed',
        name: 'Other device',
        canManage: true,
        canReply: true,
        summary: 'Summary',
        skills: ['Design'],
        updatedAt: '2026-11-11T00:00:00Z',
      );
      repo.failure = null;
      await open(tester, repo);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Review profile changes'), findsOneWidget);
      expect(repo.commands, hasLength(1));
      await tester.tap(find.text('Use saved values'));
      await tester.pumpAndSettle();
      expect(repo.commands, hasLength(2));
      final saved = jsonDecode(repo.commands.last) as Map;
      expect(saved['profile']['name'], 'Other device');
      expect(saved['expected_updated_at'], repo.remote.updatedAt);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
