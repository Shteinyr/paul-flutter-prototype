import 'dart:async';

import 'package:flutter/material.dart';

import '../live/chat_api.dart';
import '../profile/public_profile_view.dart';
import 'admin_api.dart';
import 'managed_profile_editor.dart';
import 'managed_profile_header.dart';
import 'operator_inbox_view.dart';

class ManagedProfileWorkspace extends StatefulWidget {
  const ManagedProfileWorkspace({
    super.key,
    required this.repository,
    required this.profileId,
    this.onDeleteProfile,
  });
  final AdminRepository repository;
  final String profileId;
  final Future<void> Function(ManagedProfile)? onDeleteProfile;
  @override
  State<ManagedProfileWorkspace> createState() =>
      _ManagedProfileWorkspaceState();
}

class _ManagedProfileWorkspaceState extends State<ManagedProfileWorkspace> {
  late String _selectedId;
  AdminAccess? _access;
  ManagedProfile? _selected;
  ChatRepository? _inbox;
  String? _error;
  bool _loading = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.profileId;
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _selected = null;
      _inbox = null;
      _error = null;
    });
    try {
      final access = await widget.repository.context();
      if (!mounted || generation != _generation) return;
      final selected = access.profiles
          .where((item) => item.id == _selectedId)
          .firstOrNull;
      if (selected == null) {
        throw const AdminException('managed_profile_forbidden');
      }
      setState(() {
        _access = access;
        _selected = selected;
        _inbox = selected.canReply
            ? widget.repository.operatorFor(selected.id)
            : null;
        _loading = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error is AdminException
              ? error.toString()
              : const AdminException('server_unavailable').toString();
        });
      }
    }
  }

  Future<void> _edit() async {
    final profile = _selected;
    if (profile == null || !profile.canManage) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ManagedProfileEditor(
          repository: widget.repository,
          profile: profile,
        ),
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Admin',
    action: IconButton(
      tooltip: 'Return to my profile',
      onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
      icon: const Icon(Icons.person_outline, color: Color(0xFF14679E)),
    ),
    child: _loading
        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
        : _selected == null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(_error ?? '', textAlign: TextAlign.center),
                ),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          )
        : Column(
            children: [
              ManagedProfileHeader(
                repository: widget.repository,
                profile: _selected!,
                nameControl: DropdownButton<String>(
                  key: const Key('managed-profile-switcher'),
                  value: _selectedId,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final profile in _access!.profiles)
                      DropdownMenuItem(
                        value: profile.id,
                        child: Text(
                          profile.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                  onChanged: (id) {
                    if (id == null || id == _selectedId) return;
                    _selectedId = id;
                    unawaited(_load());
                  },
                ),
              ),
              if (_selected!.canManage)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 28),
                    child: TextButton.icon(
                      onPressed: _edit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit profile'),
                    ),
                  ),
                ),
              const Divider(color: Color(0xFFCDDEE8)),
              if (_selected!.canManage && widget.onDeleteProfile != null)
                TextButton.icon(
                  onPressed: () async {
                    await widget.onDeleteProfile!(_selected!);
                    if (mounted) await _load();
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete user'),
                ),
              Expanded(
                child: _inbox == null
                    ? const Center(
                        child: Text(
                          'Replies are unavailable for this profile.',
                        ),
                      )
                    : OperatorInboxView(
                        key: ValueKey('workspace-$_selectedId-$_generation'),
                        repository: _inbox!,
                        actorId: widget.repository.userId,
                        profile: _selected!,
                        embedded: true,
                        senderAvatar: ManagedProfileAvatar(
                          repository: widget.repository,
                          profile: _selected!,
                          size: 65,
                        ),
                      ),
              ),
            ],
          ),
  );

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}
