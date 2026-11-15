import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import 'photo_picker.dart';
import 'photo_selection_journal.dart';

/// Native host supplies the private SQLite journal and calls recover at startup.
/// Recovery stages data only. The host must check pendingFor against its current
/// identity/destination, save that draft/profile, then complete the exact intent.
class RecoverablePhotoPicker {
  RecoverablePhotoPicker({
    required this.journal,
    ImagePicker? picker,
    bool? retrieveLostData,
  }) : _picker = picker ?? ImagePicker(),
       _retrieveLostData =
           retrieveLostData ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  final PhotoSelectionJournal journal;
  final ImagePicker _picker;
  final bool _retrieveLostData;
  Future<void>? _recovering;
  bool _recovered = false;
  bool _picking = false;
  XFile? _lostFile;
  PendingPhotoSelection? _unstaged;

  Future<void> recover() {
    if (_picking) return Future.error(StateError('Photo picker is active.'));
    if (_recovered) return Future.value();
    return _recovering ??= _recover().whenComplete(() => _recovering = null);
  }

  Future<void> _recover() async {
    final pending = journal.read();
    if (pending?.photo != null) {
      _recovered = true;
      return;
    }
    // Keep a consumed plugin result in memory if a local write temporarily fails.
    if (_unstaged != null) {
      journal.stage(_unstaged!.intent, _unstaged!.photo!);
      _unstaged = null;
      _lostFile = null;
      _recovered = true;
      return;
    }
    if (_retrieveLostData && _lostFile == null) {
      final lost = await _picker.retrieveLostData();
      if (pending != null && !lost.isEmpty) {
        if (lost.exception != null) {
          journal.complete(pending.intent);
          throw const PhotoSelectionException(
            'This image could not be opened.',
          );
        }
        _lostFile = lost.files?.firstOrNull ?? lost.file;
      }
      // With no saved intent the result is orphaned: drain it, never assign it
      // to whichever account happens to be signed in after process restart.
    }
    if (pending != null) {
      if (_lostFile == null) {
        journal.complete(pending.intent); // Cancellation/no recoverable result.
      } else {
        final photo = await _read(_lostFile!, pending.intent);
        _unstaged = PendingPhotoSelection(pending.intent, photo);
        journal.stage(pending.intent, photo);
        _unstaged = null;
        _lostFile = null;
      }
    }
    _recovered = true;
  }

  Future<Uint8List?> pick(PhotoSelectionIntent intent) async {
    if (_picking) throw StateError('Photo picker is active.');
    await recover();
    if (_picking) throw StateError('Photo picker is active.');
    _picking = true;
    try {
      journal.prepare(intent); // Commit identity BEFORE handing control to OS.
      XFile? file;
      try {
        file = await _picker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1024,
          maxHeight: 1024,
          imageQuality: 85,
          requestFullMetadata: false,
        );
      } catch (_) {
        journal.complete(intent);
        rethrow;
      }
      if (file == null) {
        journal.complete(intent);
        return null;
      }
      _lostFile = file;
      try {
        final photo = await _read(file, intent);
        _unstaged = PendingPhotoSelection(intent, photo);
        journal.stage(intent, photo);
        _unstaged = null;
        _lostFile = null;
        return photo;
      } catch (_) {
        _recovered = false;
        rethrow;
      }
    } finally {
      _picking = false;
    }
  }

  Future<Uint8List> _read(XFile file, PhotoSelectionIntent intent) async {
    try {
      return await readProfilePhotoFile(file);
    } on PhotoSelectionException {
      journal.complete(intent);
      _lostFile = null;
      rethrow;
    }
  }
}
