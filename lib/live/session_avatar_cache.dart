import 'dart:typed_data';

/// Bounded, in-memory media for one admitted session. Never persists photos or
/// keeps a failed request, and discards completions from an invalidated scope.
class SessionAvatarCache {
  SessionAvatarCache({this.maxEntries = 128, this.maxBytes = 32 * 1024 * 1024});
  final int maxEntries;
  final int maxBytes;
  final _ready = <(String, String), Uint8List>{};
  final _pending = <(String, String), Future<Uint8List?>>{};
  int _bytes = 0, _generation = 0;

  Uint8List? peek(String profileId, String? path) {
    final key = (profileId, path ?? '');
    final value = _ready.remove(key);
    if (value != null) _ready[key] = value;
    return value;
  }

  Future<Uint8List?> read(
    String profileId,
    String? path,
    Future<Uint8List> Function() load,
  ) {
    if (path == null) {
      evict(profileId);
      return Future.value(null);
    }
    final key = (profileId, path);
    final value = peek(profileId, path);
    if (value != null) return Future.value(value);
    final pending = _pending[key];
    if (pending != null) return pending;
    final generation = _generation;
    late final Future<Uint8List?> operation;
    operation = Future.sync(load)
        .then<Uint8List?>((value) {
          if (generation != _generation ||
              !identical(_pending[key], operation)) {
            return null;
          }
          if (value.lengthInBytes <= maxBytes) {
            _ready[key] = value;
            _bytes += value.lengthInBytes;
            while (_ready.length > maxEntries || _bytes > maxBytes) {
              _bytes -= _ready.remove(_ready.keys.first)!.lengthInBytes;
            }
          }
          return value;
        })
        .whenComplete(() {
          if (identical(_pending[key], operation)) _pending.remove(key);
        });
    _pending[key] = operation;
    return operation;
  }

  void evict(String profileId) {
    for (final key
        in _ready.keys.where((key) => key.$1 == profileId).toList()) {
      _bytes -= _ready.remove(key)!.lengthInBytes;
    }
    _pending.removeWhere((key, _) => key.$1 == profileId);
  }

  void clear() {
    _generation++;
    _ready.clear();
    _pending.clear();
    _bytes = 0;
  }
}
