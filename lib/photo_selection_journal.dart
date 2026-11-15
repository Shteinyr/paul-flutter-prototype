import 'dart:convert';
import 'dart:typed_data';

enum PhotoDestination { onboarding, profile }

/// ownerId is an Auth actor or persistent pre-auth draft ID, never a route name.
/// targetId also separates managed profiles belonging to the same Auth actor.
class PhotoSelectionIntent {
  PhotoSelectionIntent({
    required this.ownerId,
    required this.destination,
    required this.targetId,
    required this.operationId,
  }) {
    for (final key in [ownerId, targetId, operationId]) {
      if (key.isEmpty || key.length > 512 || key.contains('\u0000')) {
        throw ArgumentError('Invalid photo selection identity.');
      }
    }
  }

  final String ownerId;
  final PhotoDestination destination;
  final String targetId;
  final String operationId;

  bool matches(PhotoSelectionIntent other) =>
      ownerId == other.ownerId &&
      destination == other.destination &&
      targetId == other.targetId &&
      operationId == other.operationId;
}

class PendingPhotoSelection {
  PendingPhotoSelection(this.intent, [Uint8List? photo])
    : photo = photo == null
          ? null
          : Uint8List.fromList(photo).asUnmodifiableView();

  final PhotoSelectionIntent intent;
  final Uint8List? photo;
}

/// One device-wide slot: Android's lost picker result has no account identifier.
/// Bind these synchronous callbacks to the existing private SQLite scoped-value
/// store. Writes/removals must commit before returning; never use preferences.
/// Construct one journal/picker service at bootstrap, before any gallery opens.
class PhotoSelectionJournal {
  const PhotoSelectionJournal({
    required String? Function() read,
    required void Function(String) write,
    required void Function() remove,
  }) : _read = read,
       _write = write,
       _remove = remove;

  final String? Function() _read;
  final void Function(String) _write;
  final void Function() _remove;
  static const maxPhotoBytes = 3 * 1024 * 1024;

  PendingPhotoSelection? read() {
    final raw = _read();
    if (raw == null) return null;
    if (raw.length > 4 * maxPhotoBytes ~/ 3 + 8192) {
      throw const FormatException('Invalid saved photo selection.');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        value['version'] != 1 ||
        value['owner'] is! String ||
        value['target'] is! String ||
        value['operation'] is! String ||
        !PhotoDestination.values.any((d) => d.name == value['destination']) ||
        (value['photo'] != null && value['photo'] is! String)) {
      throw const FormatException('Invalid saved photo selection.');
    }
    final encoded = value['photo'] as String?;
    final photo = encoded == null ? null : base64Decode(encoded);
    if (photo != null && (photo.isEmpty || photo.length > maxPhotoBytes)) {
      throw const FormatException('Invalid saved photo selection.');
    }
    return PendingPhotoSelection(
      PhotoSelectionIntent(
        ownerId: value['owner'] as String,
        targetId: value['target'] as String,
        operationId: value['operation'] as String,
        destination: PhotoDestination.values.byName(
          value['destination'] as String,
        ),
      ),
      photo,
    );
  }

  void prepare(PhotoSelectionIntent intent) {
    if (read() != null) throw StateError('A photo selection is pending.');
    _save(PendingPhotoSelection(intent));
  }

  void stage(PhotoSelectionIntent intent, Uint8List photo) {
    if (photo.isEmpty || photo.length > maxPhotoBytes) {
      throw const FormatException('Invalid selected photo.');
    }
    _require(intent);
    _save(PendingPhotoSelection(intent, photo));
  }

  /// Call only AFTER the matching destination has durably saved this photo.
  void complete(PhotoSelectionIntent intent) {
    _require(intent);
    _remove();
  }

  PendingPhotoSelection? pendingFor({
    required String ownerId,
    required PhotoDestination destination,
    required String targetId,
  }) {
    final pending = read();
    final intent = pending?.intent;
    return intent?.ownerId == ownerId &&
            intent?.destination == destination &&
            intent?.targetId == targetId
        ? pending
        : null;
  }

  void _require(PhotoSelectionIntent intent) {
    if (read()?.intent.matches(intent) != true) {
      throw StateError('Photo selection owner or operation changed.');
    }
  }

  void _save(PendingPhotoSelection pending) => _write(
    jsonEncode({
      'version': 1,
      'owner': pending.intent.ownerId,
      'destination': pending.intent.destination.name,
      'target': pending.intent.targetId,
      'operation': pending.intent.operationId,
      'photo': pending.photo == null ? null : base64Encode(pending.photo!),
    }),
  );
}
