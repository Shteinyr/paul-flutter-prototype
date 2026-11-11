import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import 'profile_store.dart';
import 'user_profile.dart';

class ProfileController extends ChangeNotifier {
  ProfileController(this._store, {int? offeringLimit})
    : _offeringLimit = offeringLimit;

  final ProfileStore _store;
  UserProfile _profile = UserProfile.empty;
  Timer? _saveTimer;
  Future<void> _queue = Future<void>.value();
  bool _disposed = false;
  int _revision = 0;
  int _savedRevision = 0;
  int _generation = 0;
  int? _offeringLimit;
  int _savedOfferingCount = 0;
  int? get offeringLimit => _offeringLimit == null
      ? null
      : _savedOfferingCount > _offeringLimit!
      ? _savedOfferingCount
      : _offeringLimit;

  void setOfferingLimit(int? value) {
    _offeringLimit = value;
    _notify();
  }

  UserProfile get profile => _profile;
  int get generation => _generation;
  bool loaded = false;
  bool loadFailed = false;
  bool deleteFailed = false;
  bool deleting = false;
  String? error;

  Future<void> load() async {
    loadFailed = false;
    deleteFailed = false;
    error = null;
    _notify();
    try {
      _profile = await _store.read();
      _savedOfferingCount = _profile.skills.length;
      loaded = true;
    } catch (_) {
      loadFailed = true;
      error = 'Could not load your profile. Please try again.';
    }
    _notify();
  }

  void updateName(String value) => _change(_profile.copyWith(name: value));
  void updateOccupation(String value) =>
      _change(_profile.copyWith(occupation: value));
  void updateSummary(String value) =>
      _change(_profile.copyWith(summary: value));

  bool addSkill(String value, {bool searching = false}) {
    if (!loaded || deleting) return false;
    final skill = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    final current = searching ? _profile.searchingSkills : _profile.skills;
    final limit = offeringLimit;
    if (!searching && limit != null && current.length >= limit) return false;
    if (skill.isEmpty ||
        skill.characters.length > 64 ||
        current.any((item) => item.toLowerCase() == skill.toLowerCase())) {
      return false;
    }
    final next = [...current, skill];
    _change(
      searching
          ? _profile.copyWith(searchingSkills: next)
          : _profile.copyWith(skills: next),
    );
    return true;
  }

  void removeSkill(String skill, {bool searching = false}) {
    final current = searching ? _profile.searchingSkills : _profile.skills;
    final next = current.where((item) => item != skill).toList();
    _change(
      searching
          ? _profile.copyWith(searchingSkills: next)
          : _profile.copyWith(skills: next),
    );
  }

  void updatePhoto(Uint8List value) =>
      _change(_profile.copyWith(photo: Uint8List.fromList(value)));
  void removePhoto() => _change(_profile.withoutPhoto());

  void _change(UserProfile value) {
    if (!loaded || deleting) return;
    _profile = value;
    _revision++;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () {
      _saveTimer = null;
      unawaited(flush());
    });
    _notify();
  }

  /// Serialize writes so an older save cannot overwrite newer edits/deletion.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!loaded || deleting || _savedRevision == _revision) return _queue;
    final snapshot = _profile;
    final revision = _revision;
    _queue = _queue.then((_) async {
      try {
        await _store.write(snapshot);
        _savedOfferingCount = snapshot.skills.length;
        _savedRevision = revision;
        if (_savedRevision == _revision) {
          error = null;
          deleteFailed = false;
        }
      } catch (_) {
        deleteFailed = false;
        error = 'Changes could not be saved. Tap Retry.';
      }
      _notify();
    });
    return _queue;
  }

  Future<bool> deleteProfile() async {
    if (deleting || !loaded) return false;
    deleteFailed = false;
    deleting = true;
    _saveTimer?.cancel();
    _saveTimer = null;
    _generation++;
    _notify();
    await _queue;
    try {
      await _store.clear();
      _savedOfferingCount = 0;
      _profile = UserProfile.empty;
      _revision++;
      _savedRevision = _revision;
      error = null;
      deleting = false;
      _notify();
      return true;
    } catch (_) {
      deleteFailed = true;
      deleting = false;
      error = 'Could not delete your profile. Please try again.';
      _notify();
      return false;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _disposed = true;
    super.dispose();
  }
}
