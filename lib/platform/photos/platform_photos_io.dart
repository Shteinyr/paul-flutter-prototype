import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../photo_picker.dart';
import '../../photo_selection_journal.dart';
import '../../recoverable_photo_picker.dart';
import '../../live/chat_api.dart' show newChatOperationId;
import '../storage/native_session_storage.dart';

bool get _mobile => Platform.isIOS || Platform.isAndroid;
const _globalKey = 'photo.selection.v1';
const _ownerKey = 'photo.onboarding.owner.v1';
RecoverablePhotoPicker? _picker;
NativeSessionStorage get _storage => NativeSessionStorage.current;
String _scope(String owner, PhotoDestination destination) =>
    destination == PhotoDestination.profile
    ? accountStorageScope(owner)
    : 'photo-draft:$owner';
String _key(PhotoDestination destination, String target) =>
    'photo.${destination.name}.$target';
PhotoSelectionJournal _journal(String scope, String key) =>
    PhotoSelectionJournal(
      read: () => _storage.database.read(scope, key),
      write: (value) => _storage.database.write(scope, key, value),
      remove: () => _storage.database.remove(scope, key),
    );
PhotoSelectionJournal get _global => _journal('installation', _globalKey);
void _archiveSelection() {
  final pending = _global.read();
  if (pending?.photo == null) return;
  final intent = pending!.intent;
  final raw = _storage.database.read('installation', _globalKey)!;
  // Copy first, then acknowledge the global OS slot. A crash between commits
  // safely copies the same operation again, never to a different owner.
  _storage.database.write(
    _scope(intent.ownerId, intent.destination),
    _key(intent.destination, intent.targetId),
    raw,
  );
  _global.complete(intent);
}

Future<void> recoverPlatformPhotos() async {
  if (!_mobile) return;
  _picker ??= RecoverablePhotoPicker(journal: _global);
  await _picker!.recover();
  _archiveSelection();
}

String onboardingPhotoOwner() {
  if (!_mobile) return 'desktop-onboarding';
  final saved = _storage.read(_ownerKey);
  if (saved != null) return saved;
  final owner = newChatOperationId();
  _storage.write(_ownerKey, owner);
  return owner;
}

void clearOnboardingPhotoOwner() {
  if (!_mobile) return;
  final owner = _storage.read(_ownerKey);
  if (owner != null) _storage.database.deleteScope('photo-draft:$owner');
  _storage.remove(_ownerKey);
}

Future<Uint8List?> pickPlatformPhoto({
  required String ownerId,
  required PhotoDestination destination,
  required String targetId,
}) async {
  if (!_mobile) return pickProfilePhoto();
  await recoverPlatformPhotos();
  final intent = PhotoSelectionIntent(
    ownerId: ownerId,
    destination: destination,
    targetId: targetId,
    operationId: newChatOperationId(),
  );
  final photo = await _picker!.pick(intent);
  _archiveSelection();
  return photo;
}

Uint8List? pendingPlatformPhoto({
  required String ownerId,
  required PhotoDestination destination,
  required String targetId,
}) {
  if (!_mobile) return null;
  return _journal(_scope(ownerId, destination), _key(destination, targetId))
      .pendingFor(
        ownerId: ownerId,
        destination: destination,
        targetId: targetId,
      )
      ?.photo;
}

void completePlatformPhoto({
  required String ownerId,
  required PhotoDestination destination,
  required String targetId,
  required Uint8List photo,
}) {
  if (!_mobile) return;
  final journal = _journal(
    _scope(ownerId, destination),
    _key(destination, targetId),
  );
  final pending = journal.pendingFor(
    ownerId: ownerId,
    destination: destination,
    targetId: targetId,
  );
  if (pending?.photo != null && listEquals(pending!.photo, photo)) {
    journal.complete(pending.intent);
  }
}
