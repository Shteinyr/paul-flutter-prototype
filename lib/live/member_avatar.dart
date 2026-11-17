import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app.dart' show ProfileAvatar;
import 'live_api.dart';

/// Uses the same session cache for Contacts, search, Chat, Hiring and profiles.
class MemberAvatar extends StatefulWidget {
  const MemberAvatar({
    super.key,
    required this.api,
    required this.profileId,
    this.path,
    this.resolveProfile = false,
    this.size = 65,
    this.refreshKey,
  });
  final LiveApi api;
  final String profileId;
  final String? path;
  final bool resolveProfile;
  final double size;
  final Object? refreshKey;

  @override
  State<MemberAvatar> createState() => _MemberAvatarState();
}

class _MemberAvatarState extends State<MemberAvatar> {
  late Future<Uint8List?> _photo;
  String? _resolvedPath;
  bool _failed = false;
  int _generation = 0;
  Uint8List? get _cached => widget.api.cachedPhoto(
    widget.profileId,
    widget.resolveProfile
        ? widget.api.cachedMember(widget.profileId)?.avatarPath
        : widget.path,
  );

  void _load() {
    final generation = ++_generation;
    _failed = false;
    _resolvedPath = widget.resolveProfile
        ? widget.api.cachedMember(widget.profileId)?.avatarPath
        : widget.path;
    final future = widget.resolveProfile
        ? _resolve(widget.api, widget.profileId, generation)
        : widget.api.photoAt(widget.profileId, widget.path);
    _photo = future.then(
      (bytes) {
        if (generation != _generation) return null;
        return bytes;
      },
      onError: (Object error, StackTrace stack) {
        if (generation != _generation) return null;
        _failed = true;
        Error.throwWithStackTrace(error, stack);
      },
    );
  }

  Future<Uint8List?> _resolve(LiveApi api, String id, int generation) async {
    final profile = api.cachedMember(id) ?? await api.member(id);
    if (generation != _generation) return null;
    // This is the version actually requested, not a later cache snapshot.
    // If it is invalidated while downloading, the next update still sees the
    // version difference and starts the replacement rather than keeping null.
    _resolvedPath = profile.avatarPath;
    return api.photo(profile);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MemberAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.profileId != widget.profileId ||
        oldWidget.path != widget.path ||
        oldWidget.resolveProfile != widget.resolveProfile ||
        (widget.resolveProfile &&
            _resolvedPath !=
                widget.api.cachedMember(widget.profileId)?.avatarPath) ||
        (_failed && oldWidget.refreshKey != widget.refreshKey)) {
      _load();
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    key: ValueKey((widget.profileId, _resolvedPath, widget.resolveProfile)),
    future: _photo,
    initialData: _cached,
    builder: (_, snapshot) => ProfileAvatar(
      photo: _cached ?? (snapshot.hasError ? null : snapshot.data),
      size: widget.size,
    ),
  );
}
