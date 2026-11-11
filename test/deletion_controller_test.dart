import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/account/deletion.dart';

const actor = '10000000-0000-4000-8000-000000000001';
const other = '10000000-0000-4000-8000-000000000002';

class MemoryDeletionStore implements DeletionStore {
  final saved = <String, DeletionRecord>{};
  bool failRead = false;
  bool failWrite = false;
  bool failRemove = false;
  Completer<void>? writing;
  @override
  Future<List<DeletionRecord>> read() async {
    if (failRead) throw StateError('Storage read failed');
    return saved.values.toList();
  }

  @override
  Future<void> write(DeletionRecord record) async {
    if (writing != null) await writing!.future;
    if (failWrite) throw StateError('Storage write failed');
    saved[record.key] = record;
  }

  @override
  Future<void> remove(DeletionRecord record) async {
    if (failRemove) throw StateError('Storage remove failed');
    saved.remove(record.key);
  }
}

class DeletionRepo implements DeletionRepository {
  @override
  String? currentUserId = actor;
  final submitted = <DeletionRecord>[];
  final statuses = <DeletionRecord>[];
  final signedOut = <String>[];
  bool done = false;
  Future<DeletionStatus> Function(DeletionRecord)? submitting;
  Future<DeletionStatus> Function(DeletionRecord)? checking;
  @override
  Future<DeletionStatus> submit(DeletionRecord record) async {
    submitted.add(record);
    return submitting == null
        ? DeletionStatus(record.operationId, done)
        : submitting!(record);
  }

  @override
  Future<DeletionStatus> status(DeletionRecord record) async {
    statuses.add(record);
    return checking == null
        ? DeletionStatus(record.operationId, done)
        : checking!(record);
  }

  @override
  Future<void> clearAuth(String id) async {
    if (currentUserId == id) {
      signedOut.add(id);
      currentUserId = null;
    }
  }
}

void main() {
  late MemoryDeletionStore store;
  late DeletionRepo repo;
  late DeletionController controller;
  setUp(() {
    store = MemoryDeletionStore();
    repo = DeletionRepo();
    controller = DeletionController(repo, store);
  });
  tearDown(() => controller.dispose());

  test(
    'durable receipt precedes first delete and remains through pending sign-out',
    () async {
      repo.submitting = (record) async {
        expect(store.saved[record.key]?.receiptToken, record.receiptToken);
        expect(record.receiptToken, matches(RegExp(r'^[a-f0-9]{64}$')));
        return DeletionStatus(record.operationId, false);
      };
      final record = (await controller.begin(actor))!;
      expect(controller.confirmed(record), isTrue);
      expect(controller.complete(record), isFalse);
      expect(store.saved, hasLength(1));
      expect(repo.signedOut, [actor]);
      repo.done = true;
      await controller.refresh(record);
      expect(controller.complete(record), isTrue);
      expect(store.saved, isEmpty);
      expect(repo.submitted, hasLength(1));
    },
  );

  test('failed initial storage save makes zero remote calls', () async {
    store.failWrite = true;
    expect(await controller.begin(actor), isNull);
    expect(repo.submitted, isEmpty);
    expect(controller.loadError, isNotNull);
    store.failWrite = false;
    expect(await controller.begin(actor), isNotNull);
    expect(repo.submitted, hasLength(1));
  });

  test(
    'failed journal restoration blocks deletion until successful retry',
    () async {
      store.failRead = true;
      expect(await controller.begin(actor), isNull);
      expect(repo.submitted, isEmpty);
      store.failRead = false;
      expect(await controller.begin(actor), isNotNull);
    },
  );

  test(
    'lost delete acknowledgement recovers through status without JWT',
    () async {
      repo.submitting = (_) =>
          Future.error(const DeletionException('sign_in_required'));
      final record = (await controller.begin(actor))!;
      expect(repo.statuses.single.operationId, record.operationId);
      expect(controller.confirmed(record), isTrue);
      expect(controller.errors, isEmpty);
      expect(repo.currentUserId, isNull);
    },
  );

  test(
    'signed-out reload recovers only stored operation without another delete',
    () async {
      final record = DeletionRecord.create(actor);
      store.saved[record.key] = record;
      repo.currentUserId = null;
      repo.done = true;
      await controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(repo.submitted, isEmpty);
      expect(repo.statuses.single.receiptToken, record.receiptToken);
      expect(controller.complete(record), isTrue);
      expect(store.saved, isEmpty);
    },
  );

  test('late completion for account A preserves account B session', () async {
    final gate = Completer<DeletionStatus>();
    repo.submitting = (_) => gate.future;
    final future = controller.begin(actor);
    await Future<void>.delayed(Duration.zero);
    final record = repo.submitted.single;
    repo.currentUserId = other;
    gate.complete(DeletionStatus(record.operationId, true));
    await future;
    expect(repo.currentUserId, other);
    expect(repo.signedOut, isEmpty);
    expect(controller.complete(record), isTrue);
  });

  test(
    'concurrent confirmation waits for one journal write and one command',
    () async {
      final gate = Completer<void>();
      store.writing = gate;
      final first = controller.begin(actor);
      final second = controller.begin(actor);
      expect(identical(first, second), isTrue);
      gate.complete();
      expect((await first)?.operationId, (await second)?.operationId);
      expect(repo.submitted, hasLength(1));
    },
  );

  test(
    'unknown result and repeated user retry retain the exact operation',
    () async {
      repo.submitting = (_) => Future.error(StateError('Lost response'));
      repo.checking = (_) =>
          Future.error(const DeletionException('deletion_unavailable'));
      final record = (await controller.begin(actor))!;
      expect(controller.confirmed(record), isFalse);
      expect(store.saved, hasLength(1));
      repo.submitting = null;
      await controller.retry(record);
      expect(repo.submitted.last.toJson(), repo.submitted.first.toJson());
      expect(repo.currentUserId, isNull);
    },
  );

  test(
    'local cleanup failure retries storage without resending known complete delete',
    () async {
      repo.done = true;
      store.failRemove = true;
      final record = (await controller.begin(actor))!;
      expect(controller.complete(record), isFalse);
      expect(store.saved, hasLength(1));
      store.failRemove = false;
      await controller.refresh(record);
      expect(controller.complete(record), isTrue);
      expect(repo.submitted, hasLength(1));
      expect(repo.statuses, isEmpty);
    },
  );

  test(
    'managed status replays frozen profile revision and operation after reload',
    () async {
      const revision = '2026-11-11T00:00:00Z';
      final record = (await controller.begin(
        actor,
        profileId: other,
        updatedAt: revision,
      ))!;
      expect(record.self, isFalse);
      expect(repo.signedOut, isEmpty);
      controller.dispose();
      controller = DeletionController(repo, store);
      await controller.load();
      await Future<void>.delayed(Duration.zero);
      expect(repo.statuses.single.operationId, record.operationId);
      expect(repo.statuses.single.expectedUpdatedAt, revision);
    },
  );

  test(
    'version conflict allows fresh review and a new deletion operation',
    () async {
      repo.submitting = (_) =>
          Future.error(const DeletionException('profile_version_conflict'));
      final rejected = (await controller.begin(
        actor,
        profileId: other,
        updatedAt: '2026-11-11T00:00:00Z',
      ))!;
      expect(controller.rejected(rejected), isTrue);
      expect(controller.complete(rejected), isFalse);
      expect(store.saved, isEmpty);
      controller.dismiss(rejected);
      repo.submitting = null;
      final fresh = (await controller.begin(
        actor,
        profileId: other,
        updatedAt: '2026-11-11T01:00:00Z',
      ))!;
      expect(fresh.operationId, isNot(rejected.operationId));
    },
  );
}
