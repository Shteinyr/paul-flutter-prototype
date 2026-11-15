import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:paul_demo/photo_picker.dart';
import 'package:paul_demo/photo_selection_journal.dart';
import 'package:paul_demo/recoverable_photo_picker.dart';
import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';
import 'package:sqlite3/sqlite3.dart';

class _Store {
  String? raw;
  bool failWrite = false;
  PhotoSelectionJournal get journal => PhotoSelectionJournal(
    read: () => raw,
    write: (value) {
      if (failWrite) throw StateError('disk unavailable');
      raw = value;
    },
    remove: () => raw = null,
  );
}

class _Picker extends ImagePicker {
  Future<XFile?> Function()? choose;
  LostDataResponse? lost;
  Future<LostDataResponse> Function()? retrieve;
  int recoveries = 0;
  int picks = 0;
  @override
  Future<LostDataResponse> retrieveLostData() async {
    recoveries++;
    if (retrieve != null) return retrieve!();
    final response = lost ?? LostDataResponse.empty();
    lost = null;
    return response;
  }

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    picks++;
    expect(source, ImageSource.gallery);
    expect(maxWidth, 1024);
    expect(requestFullMetadata, isFalse);
    return choose?.call();
  }
}

PhotoSelectionIntent _intent({
  String owner = 'actor-a',
  PhotoDestination destination = PhotoDestination.profile,
  String target = 'profile-a',
  String operation = 'operation-a',
}) => PhotoSelectionIntent(
  ownerId: owner,
  destination: destination,
  targetId: target,
  operationId: operation,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late XFile image;
  setUpAll(() async {
    final data = await rootBundle.load('assets/people/julia-robinson.png');
    image = XFile.fromData(data.buffer.asUint8List(), name: 'photo.png');
  });

  test(
    'intent commits before OS gallery and result waits for durable host save',
    () async {
      final store = _Store();
      final intent = _intent();
      final picker = _Picker()
        ..choose = () async {
          expect(store.journal.read()!.intent.matches(intent), isTrue);
          return image;
        };
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: true,
      );
      final photo = await service.pick(intent);
      expect(photo, isNotEmpty);
      expect(store.journal.read()!.photo, photo);
      expect(picker.recoveries, 1);
      expect(picker.picks, 1);
      // A restarted journal retains the normalized bytes until explicit receipt.
      store.journal.complete(intent);
      expect(store.raw, isNull);
    },
  );

  for (final destination in PhotoDestination.values) {
    test(
      'process restart recovers only the saved $destination owner and target',
      () async {
        final store = _Store();
        final intent = _intent(destination: destination);
        store.journal.prepare(intent);
        final picker = _Picker()..lost = LostDataResponse(files: [image]);
        final service = RecoverablePhotoPicker(
          journal: store.journal,
          picker: picker,
          retrieveLostData: true,
        );
        await Future.wait([service.recover(), service.recover()]);
        expect(picker.recoveries, 1);
        expect(
          store.journal.pendingFor(
            ownerId: 'other',
            destination: destination,
            targetId: 'profile-a',
          ),
          isNull,
        );
        expect(
          store.journal.pendingFor(
            ownerId: 'actor-a',
            destination: destination,
            targetId: 'managed-b',
          ),
          isNull,
        );
        final opposite = destination == PhotoDestination.profile
            ? PhotoDestination.onboarding
            : PhotoDestination.profile;
        expect(
          store.journal.pendingFor(
            ownerId: 'actor-a',
            destination: opposite,
            targetId: 'profile-a',
          ),
          isNull,
        );
        final result = store.journal.pendingFor(
          ownerId: 'actor-a',
          destination: destination,
          targetId: 'profile-a',
        )!;
        expect(result.intent.operationId, intent.operationId);
        expect(result.photo, isNotEmpty);
        // Another death between staging and applying does not ask Android again.
        final nextPicker = _Picker();
        await RecoverablePhotoPicker(
          journal: store.journal,
          picker: nextPicker,
          retrieveLostData: true,
        ).recover();
        expect(nextPicker.recoveries, 0);
        expect(store.journal.read()!.photo, result.photo);
      },
    );
  }

  test('failed intent persistence never opens gallery', () async {
    final store = _Store()..failWrite = true;
    final picker = _Picker();
    final service = RecoverablePhotoPicker(
      journal: store.journal,
      picker: picker,
      retrieveLostData: false,
    );
    await expectLater(service.pick(_intent()), throwsStateError);
    expect(picker.picks, 0);
  });

  test(
    'cancelled picker leaves destination unchanged and clears intent',
    () async {
      final store = _Store();
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: _Picker(),
        retrieveLostData: false,
      );
      expect(await service.pick(_intent()), isNull);
      expect(store.raw, isNull);
    },
  );

  test(
    'OS picker failure clears selection without replacing destination photo',
    () async {
      final store = _Store();
      final picker = _Picker()
        ..choose = () async => throw PlatformException(code: 'denied');
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: false,
      );
      await expectLater(
        service.pick(_intent()),
        throwsA(isA<PlatformException>()),
      );
      expect(store.raw, isNull);
    },
  );

  test(
    'orphaned result is drained instead of assigned to the current account',
    () async {
      final store = _Store();
      final picker = _Picker()..lost = LostDataResponse(files: [image]);
      await RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: true,
      ).recover();
      expect(picker.recoveries, 1);
      expect(store.raw, isNull);
    },
  );

  test('empty result releases interrupted selection', () async {
    final store = _Store();
    store.journal.prepare(_intent());
    await RecoverablePhotoPicker(
      journal: store.journal,
      picker: _Picker(),
      retrieveLostData: true,
    ).recover();
    expect(store.raw, isNull);
  });

  test('lost plugin error retains the old destination photo', () async {
    final store = _Store();
    store.journal.prepare(_intent());
    final picker = _Picker()
      ..lost = LostDataResponse(exception: PlatformException(code: 'denied'));
    await expectLater(
      RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: true,
      ).recover(),
      throwsA(isA<PhotoSelectionException>()),
    );
    expect(store.raw, isNull);
  });

  test('oversized recovered image uses original 3 MB limit', () async {
    final store = _Store();
    store.journal.prepare(_intent());
    final oversized = XFile.fromData(
      Uint8List(PhotoSelectionJournal.maxPhotoBytes + 1),
    );
    final picker = _Picker()..lost = LostDataResponse(files: [oversized]);
    await expectLater(
      RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: true,
      ).recover(),
      throwsA(isA<PhotoSelectionException>()),
    );
    expect(store.raw, isNull);
  });

  test(
    'corrupt recovered image cannot replace the existing profile photo',
    () async {
      final store = _Store();
      store.journal.prepare(_intent());
      final picker = _Picker()
        ..lost = LostDataResponse(
          files: [
            XFile.fromData(Uint8List.fromList([1, 2, 3])),
          ],
        );
      await expectLater(
        RecoverablePhotoPicker(
          journal: store.journal,
          picker: picker,
          retrieveLostData: true,
        ).recover(),
        throwsA(isA<PhotoSelectionException>()),
      );
      expect(store.raw, isNull);
    },
  );

  test(
    'staging failure retries consumed lost data in the same service',
    () async {
      final store = _Store();
      store.journal.prepare(_intent());
      store.failWrite = true;
      final picker = _Picker()..lost = LostDataResponse(files: [image]);
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: true,
      );
      await expectLater(service.recover(), throwsStateError);
      store.failWrite = false;
      await service.recover();
      expect(picker.recoveries, 1);
      expect(store.journal.read()!.photo, isNotEmpty);
    },
  );

  test(
    'staging failure after a normal choice can retry without reopening gallery',
    () async {
      final store = _Store();
      final picker = _Picker()
        ..choose = () async {
          store.failWrite = true;
          return image;
        };
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: false,
      );
      await expectLater(service.pick(_intent()), throwsStateError);
      store.failWrite = false;
      await service.recover();
      expect(picker.picks, 1);
      expect(store.journal.read()!.photo, isNotEmpty);
    },
  );

  test(
    'wrong owner and stale receipt cannot delete or overwrite a newer operation',
    () {
      final store = _Store();
      final pending = _intent();
      store.journal.prepare(pending);
      expect(
        () => store.journal.complete(_intent(owner: 'other')),
        throwsStateError,
      );
      expect(
        () => store.journal.stage(
          _intent(operation: 'old'),
          Uint8List.fromList([1]),
        ),
        throwsStateError,
      );
      expect(
        () => store.journal.prepare(_intent(operation: 'new')),
        throwsStateError,
      );
      expect(store.journal.read()!.intent.matches(pending), isTrue);
    },
  );

  test(
    'a second request cannot replace an active native picker intent',
    () async {
      final store = _Store();
      final selection = Completer<XFile?>();
      final opened = Completer<void>();
      final picker = _Picker()
        ..choose = () {
          opened.complete();
          return selection.future;
        };
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: false,
      );
      final first = service.pick(_intent());
      await opened.future;
      await expectLater(
        service.pick(_intent(owner: 'other')),
        throwsStateError,
      );
      await expectLater(service.recover(), throwsStateError);
      selection.complete(null);
      await first;
      expect(picker.picks, 1);
    },
  );

  test(
    'malformed journal blocks gallery and does not consume the native result',
    () async {
      final store = _Store()..raw = '{"version":1}';
      final picker = _Picker();
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: true,
      );
      await expectLater(service.pick(_intent()), throwsFormatException);
      expect(picker.picks, 0);
      expect(picker.recoveries, 0);
    },
  );

  for (final stage in ['picker', 'lost recovery']) {
    test(
      'account deletion discards late $stage result without recreating private data',
      () async {
        final db = SqliteJournalStore.fromDatabase(sqlite3.openInMemory());
        final journal = PhotoSelectionJournal(
          read: () => db.read('installation', 'photo.selection.v1'),
          write: (value) =>
              db.write('installation', 'photo.selection.v1', value),
          remove: () => db.remove('installation', 'photo.selection.v1'),
        );
        final pickerResult = Completer<XFile?>();
        final lostResult = Completer<LostDataResponse>();
        final opened = Completer<void>();
        final picker = _Picker();
        if (stage == 'picker') {
          picker.choose = () {
            opened.complete();
            return pickerResult.future;
          };
        } else {
          journal.prepare(_intent());
          picker.retrieve = () {
            opened.complete();
            return lostResult.future;
          };
        }
        final service = RecoverablePhotoPicker(
          journal: journal,
          picker: picker,
          retrieveLostData: stage != 'picker',
        );
        final Future<Object?> pending = stage == 'picker'
            ? service.pick(_intent())
            : service.recover();
        await opened.future;
        db.deleteAccountData('actor-a');
        expect(journal.read(), isNull);
        if (stage == 'picker') {
          pickerResult.complete(image);
        } else {
          lostResult.complete(LostDataResponse(files: [image]));
        }
        expect(await pending, isNull);
        expect(journal.read(), isNull);
        expect(
          () => db.write('account:actor-a', 'photo', 'late result'),
          throwsStateError,
        );
        await service
            .recover(); // Startup stays usable after discarding the result.
        picker.choose = () async => image;
        final next = await service.pick(
          _intent(owner: 'other', target: 'managed-other'),
        );
        expect(next, isNotEmpty);
        expect(journal.read()!.intent.ownerId, 'other');
        db.close();
      },
    );
  }

  test(
    'deleting a failed staging owner releases its retained in-memory photo',
    () async {
      final store = _Store();
      final picker = _Picker()
        ..choose = () async {
          store.failWrite = true;
          return image;
        };
      final service = RecoverablePhotoPicker(
        journal: store.journal,
        picker: picker,
        retrieveLostData: false,
      );
      await expectLater(service.pick(_intent()), throwsStateError);
      store.raw = null; // Account deletion removed the global intent.
      store.failWrite = false;
      await service.recover();
      expect(store.raw, isNull);
      picker.choose = () async => image;
      expect(await service.pick(_intent(owner: 'other')), isNotEmpty);
      expect(store.journal.read()!.intent.ownerId, 'other');
    },
  );
}
