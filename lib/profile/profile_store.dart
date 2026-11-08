import 'package:shared_preferences/shared_preferences.dart';

import 'user_profile.dart';

abstract interface class ProfileStore {
  Future<UserProfile> read();
  Future<void> write(UserProfile profile);
  Future<void> clear();
}

class PreferencesProfileStore implements ProfileStore {
  PreferencesProfileStore({
    SharedPreferencesAsync? preferences,
    Future<UserProfile> Function()? seedProfile,
    Future<UserProfile> Function(UserProfile)? migrateProfile,
  }) : _preferences = preferences ?? SharedPreferencesAsync(),
       _seedProfile = seedProfile,
       _migrateProfile = migrateProfile;

  static const storageKey = 'paul.demo.profile.v1';
  final SharedPreferencesAsync _preferences;
  final Future<UserProfile> Function()? _seedProfile;
  final Future<UserProfile> Function(UserProfile)? _migrateProfile;

  @override
  Future<UserProfile> read() async {
    final saved = await _preferences.getString(storageKey);
    if (saved != null) {
      final profile = UserProfile.decode(saved);
      final migrated = await _migrateProfile?.call(profile) ?? profile;
      if (!identical(migrated, profile)) await write(migrated);
      return migrated;
    }
    if (_seedProfile == null) return UserProfile.empty;
    final sample = await _seedProfile();
    await write(sample);
    return sample;
  }

  @override
  Future<void> write(UserProfile profile) =>
      _preferences.setString(storageKey, profile.encode());

  @override
  // An explicit empty record prevents the sample from returning after deletion.
  Future<void> clear() =>
      _preferences.setString(storageKey, UserProfile.empty.encode());
}
