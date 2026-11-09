import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../profile/profile_store.dart';
import '../profile/user_profile.dart';

/// Keeps pre-registration data separate from the signed-in/demo profile.
class OnboardingDraftStore implements ProfileStore {
  OnboardingDraftStore({
    SharedPreferencesAsync? preferences,
    UserProfile? initialDraft,
  }) : _preferences = preferences ?? SharedPreferencesAsync(),
       _initialDraft = initialDraft;

  static const storageKey = 'paul.onboarding.draft.v1';
  final SharedPreferencesAsync _preferences;
  UserProfile? _initialDraft;
  Future<void> _writes = Future<void>.value();

  int step = 0;
  String offeredInput = '';
  String searchingInput = '';

  @override
  Future<UserProfile> read() async {
    final restored = _initialDraft;
    if (restored != null) {
      _initialDraft = null;
      step = 2;
      return restored;
    }
    final source = await _preferences.getString(storageKey);
    UserProfile profile = UserProfile.empty;
    if (source != null) {
      final data = jsonDecode(source);
      if (data is! Map<String, dynamic> ||
          data['version'] != 1 ||
          data['step'] is! int ||
          (data['step'] as int) < 0 ||
          (data['step'] as int) > 2 ||
          data['profile'] is! String ||
          data['offeredInput'] is! String ||
          data['searchingInput'] is! String) {
        throw const FormatException('Invalid onboarding draft.');
      }
      profile = UserProfile.decode(data['profile'] as String);
      step = data['step'] as int;
      offeredInput = data['offeredInput'] as String;
      searchingInput = data['searchingInput'] as String;
    }
    return profile;
  }

  @override
  Future<void> write(UserProfile profile) {
    final snapshot = jsonEncode({
      'version': 1,
      'profile': profile.encode(),
      'step': step,
      'offeredInput': offeredInput,
      'searchingInput': searchingInput,
    });
    // Progress and ProfileController writes share one ordered queue.
    final write = _writes.then(
      (_) => _preferences.setString(storageKey, snapshot),
    );
    _writes = write.catchError((Object _) {});
    return write;
  }

  @override
  Future<void> clear() {
    step = 0;
    offeredInput = '';
    searchingInput = '';
    return write(UserProfile.empty);
  }
}
