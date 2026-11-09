import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/profile_store.dart';
import 'package:paul_demo/profile/user_profile.dart';

class MemoryProfileStore implements ProfileStore {
  String? saved;
  bool failWrite = false;
  bool failRead = false;
  bool failDelete = false;
  Completer<void>? writeGate;

  @override
  Future<UserProfile> read() async {
    if (failRead) throw StateError('Read failed');
    return saved == null ? UserProfile.empty : UserProfile.decode(saved!);
  }

  @override
  Future<void> write(UserProfile profile) async {
    await writeGate?.future;
    if (failWrite) throw StateError('Write failed');
    saved = profile.encode();
  }

  @override
  Future<void> clear() async {
    if (failDelete) throw StateError('Delete failed');
    saved = null;
  }
}

void main() {
  test(
    'a new controller restores name, occupation and actual photo bytes',
    () async {
      final store = MemoryProfileStore();
      final controller = ProfileController(store);
      await controller.load();
      controller.updateName('Julia Robinson');
      controller.updateOccupation('UI/UX Designer');
      controller.updatePhoto(Uint8List.fromList([1, 2, 3]));
      controller.updateSummary('I build thoughtful products.');
      controller.addSkill('Flutter');
      controller.addSkill('Dart');
      controller.addSkill('Photography', searching: true);
      await controller.flush();
      controller.dispose();

      final restarted = ProfileController(store);
      await restarted.load();
      expect(restarted.profile.name, 'Julia Robinson');
      expect(restarted.profile.occupation, 'UI/UX Designer');
      expect(restarted.profile.photo, [1, 2, 3]);
      expect(restarted.profile.summary, 'I build thoughtful products.');
      expect(restarted.profile.skills, ['Flutter', 'Dart']);
      expect(restarted.profile.searchingSkills, ['Photography']);
      restarted.dispose();
    },
  );

  test('version 1 profiles keep existing data when adding Next fields', () async {
    final store = MemoryProfileStore()
      ..saved =
          '{"version":1,"name":"Existing User","occupation":"Designer","photo":"AQID"}';
    final controller = ProfileController(store);
    await controller.load();
    expect(controller.profile.photo, [1, 2, 3]);
    expect(controller.profile.summary, isEmpty);
    expect(controller.profile.skills, isEmpty);
    controller.updateSummary('An existing profile, now extended.');
    controller.addSkill('Product Design');
    await controller.flush();
    final restored = await store.read();
    expect(restored.name, 'Existing User');
    expect(restored.occupation, 'Designer');
    expect(restored.photo, [1, 2, 3]);
    expect(restored.skills, ['Product Design']);
    controller.dispose();
  });

  test(
    'skill length matches user-perceived characters in both fields',
    () async {
      final store = MemoryProfileStore();
      final controller = ProfileController(store);
      addTearDown(controller.dispose);
      await controller.load();
      final accentedSkill = List.filled(64, 'e\u0301').join();
      final emojiSkill = List.filled(64, '👨‍👩‍👦').join();

      expect(controller.addSkill(accentedSkill), isTrue);
      expect(controller.addSkill(emojiSkill, searching: true), isTrue);
      expect(controller.addSkill('${accentedSkill}a'), isFalse);
      expect(controller.addSkill('${emojiSkill}a', searching: true), isFalse);
      expect(controller.addSkill(accentedSkill), isFalse);
      expect(controller.addSkill(emojiSkill, searching: true), isFalse);

      await controller.flush();
      final restored = await store.read();
      expect(restored.skills, [accentedSkill]);
      expect(restored.searchingSkills, [emojiSkill]);
    },
  );

  test(
    'skills normalize whitespace, reject duplicates and remain independent',
    () async {
      final controller = ProfileController(MemoryProfileStore());
      await controller.load();
      expect(controller.addSkill('  Product   Design  '), isTrue);
      expect(controller.addSkill('product design'), isFalse);
      expect(controller.addSkill('   '), isFalse);
      expect(controller.addSkill('Product Design', searching: true), isTrue);
      controller.updateSummary('Summary');
      controller.updatePhoto(Uint8List.fromList([1, 2, 3]));
      controller.removePhoto();
      expect(controller.profile.summary, 'Summary');
      expect(controller.profile.skills, ['Product Design']);
      controller.removeSkill('Product Design');
      expect(controller.profile.skills, isEmpty);
      expect(controller.profile.searchingSkills, ['Product Design']);
      await controller.flush();
      await controller.deleteProfile();
      expect(controller.profile.hasData, isFalse);
      expect(controller.profile.searchingSkills, isEmpty);
      controller.dispose();
    },
  );

  test(
    'deletion waits for pending writes and cannot resurrect the profile',
    () async {
      final store = MemoryProfileStore()..writeGate = Completer<void>();
      final controller = ProfileController(store);
      await controller.load();
      controller.updateName('Julia');
      final pendingSave = controller.flush();
      final deleting = controller.deleteProfile();
      store.writeGate!.complete();
      await pendingSave;
      expect(await deleting, isTrue);
      expect(store.saved, isNull);
      expect(controller.profile.hasData, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(store.saved, isNull);
      controller.dispose();
    },
  );

  test('ordered saves preserve the newest edits', () async {
    final store = MemoryProfileStore()..writeGate = Completer<void>();
    final controller = ProfileController(store);
    await controller.load();
    controller.updateName('First');
    final first = controller.flush();
    controller.updateName('Latest');
    controller.updateOccupation('Engineer');
    final latest = controller.flush();
    store.writeGate!.complete();
    await Future.wait([first, latest]);
    expect((await store.read()).name, 'Latest');
    expect((await store.read()).occupation, 'Engineer');
    controller.dispose();
  });

  test('a failed save retains the edit and supports retry', () async {
    final store = MemoryProfileStore()..failWrite = true;
    final controller = ProfileController(store);
    await controller.load();
    controller.updateName('Julia');
    await controller.flush();
    expect(controller.error, isNotNull);
    expect(controller.profile.name, 'Julia');
    store.failWrite = false;
    await controller.flush();
    expect(controller.error, isNull);
    expect((await store.read()).name, 'Julia');
    controller.dispose();
  });

  test('failed deletion leaves the existing profile intact', () async {
    final store = MemoryProfileStore()..failDelete = true;
    final controller = ProfileController(store);
    await controller.load();
    controller.updateName('Julia');
    await controller.flush();
    expect(await controller.deleteProfile(), isFalse);
    expect(controller.profile.name, 'Julia');
    expect((await store.read()).name, 'Julia');
    expect(controller.error, isNotNull);
    controller.dispose();
  });

  test(
    'a failed load cannot overwrite previously stored information',
    () async {
      final store = MemoryProfileStore()
        ..saved = const UserProfile(name: 'Existing').encode()
        ..failRead = true;
      final controller = ProfileController(store);
      await controller.load();
      controller.updateName('Accidental overwrite');
      await controller.flush();
      expect(controller.loaded, isFalse);
      expect(controller.loadFailed, isTrue);
      store.failRead = false;
      await controller.load();
      expect(controller.profile.name, 'Existing');
      controller.dispose();
    },
  );
}
