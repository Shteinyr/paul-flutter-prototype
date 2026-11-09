import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/onboarding/onboarding_draft_store.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/profile_store.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'support/onboarding_preferences.dart';

void main() {
  test('draft restores profile, progress and unfinished skill input', () async {
    final preferences = DraftPreferences();
    preferences.values[PreferencesProfileStore.storageKey] = const UserProfile(
      name: 'Signed-in profile',
    ).encode();
    final store = OnboardingDraftStore(preferences: preferences);
    expect((await store.read()).hasData, isFalse);
    store.step = 1;
    store.offeredInput = 'Product';
    store.searchingInput = 'Photog';
    await store.write(const UserProfile(skills: ['Flutter']));

    final restored = OnboardingDraftStore(preferences: preferences);
    expect((await restored.read()).skills, ['Flutter']);
    expect(restored.step, 1);
    expect(restored.offeredInput, 'Product');
    expect(restored.searchingInput, 'Photog');
    expect(
      UserProfile.decode(
        preferences.values[PreferencesProfileStore.storageKey]!,
      ).name,
      'Signed-in profile',
    );
  });

  test('failed write can retry without poisoning later saves', () async {
    final preferences = DraftPreferences()..failWrite = true;
    final store = OnboardingDraftStore(preferences: preferences);
    await expectLater(
      store.write(const UserProfile(name: 'Retained')),
      throwsStateError,
    );
    preferences.failWrite = false;
    await store.write(const UserProfile(name: 'Retained'));
    expect((await store.read()).name, 'Retained');
  });

  test('clear follows pending writes and cannot resurrect a draft', () async {
    final preferences = DraftPreferences()..writeGate = Completer<void>();
    final store = OnboardingDraftStore(preferences: preferences)..step = 2;
    final saving = store.write(const UserProfile(name: 'Old draft'));
    final clearing = store.clear();
    preferences.writeGate!.complete();
    await Future.wait([saving, clearing]);
    final restored = OnboardingDraftStore(preferences: preferences);
    expect((await restored.read()).hasData, isFalse);
    expect(restored.step, 0);
  });

  test(
    'OAuth snapshot resumes final step without seeding sample values',
    () async {
      final store = OnboardingDraftStore(
        preferences: DraftPreferences(),
        initialDraft: const UserProfile(name: 'Restored', skills: ['Flutter']),
      );
      expect((await store.read()).name, 'Restored');
      expect(store.step, 2);
      expect(store.searchingInput, isEmpty);
    },
  );

  test(
    'existing profile controller persists normalized onboarding skills',
    () async {
      final store = OnboardingDraftStore(preferences: DraftPreferences());
      final controller = ProfileController(store);
      await controller.load();
      expect(controller.addSkill('  Product   Design '), isTrue);
      expect(controller.addSkill('product design'), isFalse);
      await controller.flush();
      expect((await store.read()).skills, ['Product Design']);
      controller.dispose();
    },
  );
}
