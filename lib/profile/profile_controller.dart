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
  UserProfile _savedProfile = UserProfile.empty;
  bool _flushScheduled = false;
  Set<String> _conflicts = {};
  Set<String> get conflictingFields => Set.unmodifiable(_conflicts);
  bool get hasConflict => _conflicts.isNotEmpty;
  bool get hasUnsavedChanges => _savedRevision != _revision;
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
  UserProfile get savedProfile => _savedProfile;
  int get generation => _generation;
  bool loaded = false;
  bool loadFailed = false;
  bool refreshFailed = false;
  bool deleteFailed = false;
  bool deleting = false;
  String? error;

  Future<void> load() async {
    loadFailed = false;
    refreshFailed = false;
    deleteFailed = false;
    error = null;
    _notify();
    try {
      _profile = await _store.read();
      _savedProfile = _profile;
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

  /// Coalesce queued saves and capture the newest draft only when the save starts.
  Future<void> flush() {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (_flushScheduled || !loaded || deleting || hasConflict) return _queue;
    _flushScheduled = true;
    _queue = _queue
        .then((_) async {
          while (!_disposed && !deleting && !hasConflict && hasUnsavedChanges) {
            final snapshot = _profile;
            final revision = _revision;
            try {
              final store = _store;
              final saved = store is ReconciledProfileStore
                  ? await store.save(snapshot)
                  : await (() async {
                      await store.write(snapshot);
                      return snapshot;
                    })();
              _savedProfile = saved;
              _profile = _profile.rebase(snapshot, saved);
              _savedOfferingCount = saved.skills.length;
              _savedRevision = revision;
              error = null;
              refreshFailed = false;
              deleteFailed = false;
            } on ProfileConflictException catch (conflict) {
              _applyRemote(conflict.saved);
              error = hasConflict
                  ? 'Your profile changed on another device. Your edits are still here. Review changes.'
                  : null;
              if (hasConflict) break;
              continue;
            } catch (_) {
              deleteFailed = false;
              refreshFailed = false;
              error = 'Changes could not be saved. Tap Retry.';
              break;
            }
            _notify();
          }
          _notify();
        })
        .whenComplete(() => _flushScheduled = false);
    return _queue;
  }

  void _applyRemote(UserProfile remote) {
    _conflicts = _profile.conflictsWith(_savedProfile, remote).union({
      for (final key in _conflicts)
        if (!profileValueEqual(
          _profile.editableFields[key],
          remote.editableFields[key],
        ))
          key,
    });
    _profile = _profile.rebase(_savedProfile, remote);
    _savedProfile = remote;
    _savedOfferingCount = remote.skills.length;
    if (_profile.changesFrom(remote).isEmpty) _savedRevision = _revision;
  }

  Future<void> refresh() async {
    if (!loaded || deleting || _disposed) return;
    refreshFailed = false;
    // Settle an uncertain write through its original receipt before a read changes
    // the baseline. Otherwise a refresh could turn an ACK retry into a new write.
    await flush();
    if (_disposed ||
        deleting ||
        (error != null && (hasUnsavedChanges || hasConflict))) {
      return;
    }
    _saveTimer?.cancel();
    _saveTimer = null;
    _queue = _queue.then((_) async {
      try {
        final remote = await _store.read();
        if (_disposed) return;
        _applyRemote(remote);
        error = hasConflict
            ? 'Your profile changed on another device. Your edits are still here. Review changes.'
            : null;
      } on ProfileConflictException catch (conflict) {
        _applyRemote(conflict.saved);
        error = hasConflict
            ? 'Your profile changed on another device. Your edits are still here. Review changes.'
            : null;
      } catch (_) {
        refreshFailed = true;
        error =
            'Could not refresh your profile. Your edits are still here. Tap Retry.';
      }
      _notify();
    });
    await _queue;
    if (!hasConflict && error == null && hasUnsavedChanges) await flush();
  }

  Future<void> resolveConflict({required bool keepLocal}) async {
    if (!hasConflict) return;
    if (!keepLocal) {
      _profile = _profile.rebase(
        _savedProfile,
        _savedProfile,
        useRemote: _conflicts,
      );
      _revision++;
    }
    _conflicts = {};
    error = null;
    if (_profile.changesFrom(_savedProfile).isEmpty) _savedRevision = _revision;
    _notify();
    await flush();
  }

  Future<bool> saveBeforeLeaving() async {
    await flush();
    return !hasUnsavedChanges && !hasConflict;
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
      _savedProfile = UserProfile.empty;
      _conflicts = {};
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
