import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:paul_demo/photo_picker.dart';
import 'package:paul_demo/profile/demo_profile.dart';
import 'package:paul_demo/profile/profile_store.dart';
import 'package:paul_demo/profile/user_profile.dart';

class _TestPreferences extends Fake implements SharedPreferencesAsync {
  final values = <String, String>{};
  @override
  Future<String?> getString(String key) async => values[key];
  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'first launch seeds a profile once and deletion survives restart',
    () async {
      final preferences = _TestPreferences();
      var seeds = 0;
      Future<UserProfile> seed() async {
        seeds++;
        return const UserProfile(
          name: 'Julia Robinson',
          occupation: 'UI/UX Designer',
          summary: 'Example',
          skills: ['Figma'],
          searchingSkills: ['Photography'],
        );
      }

      final first = PreferencesProfileStore(
        preferences: preferences,
        seedProfile: seed,
      );
      expect((await first.read()).name, 'Julia Robinson');
      final second = PreferencesProfileStore(
        preferences: preferences,
        seedProfile: seed,
      );
      expect((await second.read()).skills, ['Figma']);
      expect(seeds, 1);
      await second.clear();
      final restarted = PreferencesProfileStore(
        preferences: preferences,
        seedProfile: seed,
      );
      expect((await restarted.read()).hasData, isFalse);
      expect(seeds, 1);
    },
  );

  test('an existing edited profile is never replaced by sample data', () async {
    final preferences = _TestPreferences();
    preferences.values[PreferencesProfileStore.storageKey] = const UserProfile(
      name: 'My own profile',
    ).encode();
    final store = PreferencesProfileStore(
      preferences: preferences,
      seedProfile: () async => throw StateError('Must not seed'),
    );
    expect((await store.read()).name, 'My own profile');
  });

  test(
    'the real sample includes a small valid photo and every profile section',
    () async {
      final profile = await loadDemoProfile();
      expect(profile.name, 'Paul Galda');
      expect(profile.occupation, 'Business Analyst');
      expect(profile.photo, isNotEmpty);
      expect(profile.photo!.length, lessThan(1024 * 1024));
      expect(profile.summary, isNotEmpty);
      expect(profile.skills.length, 12);
      expect(profile.searchingSkills.length, 12);
    },
  );

  test('the previous untouched example upgrades and persists as Paul', () async {
    final image = await rootBundle.load('assets/people/julia-robinson.png');
    final old = UserProfile(
      name: 'Julia Robinson',
      occupation: 'UI/UX Designer',
      photo: await normalizeProfilePhoto(
        image.buffer.asUint8List(),
        targetWidth: 384,
      ),
      summary:
          'Hi, I am passionate Artist with a keen eye for detail and a love for creating visuals that inspire and connect. With years of experience in crafting compelling designs, I thrive on transforming ideas',
      skills: const [
        'Marketing',
        'UI Design',
        'UX Research',
        'Figma',
        'Prototyping',
      ],
      searchingSkills: const ['Dog walker', 'Photography'],
    );
    final preferences = _TestPreferences();
    preferences.values[PreferencesProfileStore.storageKey] = old.encode();
    final store = PreferencesProfileStore(
      preferences: preferences,
      seedProfile: loadDemoProfile,
      migrateProfile: migrateDemoProfile,
    );
    expect((await store.read()).name, 'Paul Galda');
    expect(
      UserProfile.decode(
        preferences.values[PreferencesProfileStore.storageKey]!,
      ).name,
      'Paul Galda',
    );

    for (final edited in [
      old.copyWith(name: 'My profile'),
      old.copyWith(summary: 'My updated summary'),
      old.copyWith(skills: ['Figma']),
      old.withoutPhoto(),
      UserProfile.empty,
    ]) {
      await store.write(edited);
      expect((await store.read()).encode(), edited.encode());
    }
    await store.clear();
    expect((await store.read()).hasData, isFalse);
  });
}
