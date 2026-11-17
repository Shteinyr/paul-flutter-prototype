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
  });
  final LiveApi api;
  final String profileId;
  final String? path;
  final bool resolveProfile;
  final double size;

  @override
  State<MemberAvatar> createState() => _MemberAvatarState();
}

class _MemberAvatarState extends State<MemberAvatar> {
  late Future<Uint8List?> _photo;
  Uint8List? get _cached => widget.api.cachedPhoto(
    widget.profileId,
    widget.resolveProfile
        ? widget.api.cachedMember(widget.profileId)?.avatarPath
        : widget.path,
  );

  void _load() {
    _photo = widget.resolveProfile
        ? widget.api.photoForProfile(widget.profileId)
        : widget.api.photoAt(widget.profileId, widget.path);
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
        oldWidget.resolveProfile != widget.resolveProfile) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    key: ValueKey((widget.profileId, widget.path, widget.resolveProfile)),
    future: _photo,
    initialData: _cached,
    builder: (_, snapshot) => ProfileAvatar(
      photo: _cached ?? (snapshot.hasError ? null : snapshot.data),
      size: widget.size,
    ),
  );
}
