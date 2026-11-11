import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app.dart';
import 'admin_api.dart';

class ManagedProfileAvatar extends StatefulWidget {
  const ManagedProfileAvatar({
    super.key,
    required this.repository,
    required this.profile,
    this.size = 48,
  });
  final AdminRepository repository;
  final ManagedProfile profile;
  final double size;
  @override
  State<ManagedProfileAvatar> createState() => _ManagedProfileAvatarState();
}

class _ManagedProfileAvatarState extends State<ManagedProfileAvatar> {
  late Future<Uint8List?> _photo;
  void _load() {
    _photo = Future<Uint8List?>.sync(
      () => widget.repository.photo(widget.profile),
    );
    _photo.ignore();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ManagedProfileAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository ||
        oldWidget.profile.id != widget.profile.id ||
        oldWidget.profile.avatarPath != widget.profile.avatarPath ||
        oldWidget.profile.updatedAt != widget.profile.updatedAt) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _photo,
    builder: (_, snapshot) => ProfileAvatar(
      photo: snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null,
      size: widget.size,
    ),
  );
}

class ManagedProfileHeader extends StatelessWidget {
  const ManagedProfileHeader({
    super.key,
    required this.repository,
    required this.profile,
    this.nameControl,
  });
  final AdminRepository repository;
  final ManagedProfile profile;
  final Widget? nameControl;
  @override
  Widget build(BuildContext context) => Padding(
    key: ValueKey('managed-context-${profile.id}'),
    padding: const EdgeInsets.fromLTRB(28, 18, 28, 10),
    child: Row(
      children: [
        ManagedProfileAvatar(repository: repository, profile: profile),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              nameControl ??
                  Text(
                    profile.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              if (profile.occupation.isNotEmpty)
                Text(
                  profile.occupation,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
