import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app.dart';
import '../live/chat_api.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_conflict_dialog.dart';
import '../platform/photos/platform_photos.dart';
import 'managed_profile_write_journal.dart';
import '../profile/profile_store.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';
import 'admin_api.dart';
import 'managed_profile_header.dart';

class ManagedProfileEditor extends StatefulWidget {
  const ManagedProfileEditor({
    super.key,
    required this.repository,
    this.profile,
  });
  final AdminRepository repository;
  final ManagedProfile? profile;
  @override
  State<ManagedProfileEditor> createState() => _ManagedProfileEditorState();
}

class _ManagedProfileEditorState extends State<ManagedProfileEditor> {
  ProfileController? _controller;
  String? _error;
  bool _busy = true;
  Map<String, dynamic>? _pending;
  late final ManagedProfileWriteJournal _journal;
  late final String _actor;
  String? _session;
  String get _photoTarget => 'managed:${widget.profile?.id ?? 'create'}';
  UserProfile _base = UserProfile.empty;
  String? _version;
  String? _avatarPath;

  void _checkActor() {
    if (widget.repository.userId != _actor) {
      throw const AdminException('sign_in_required');
    }
    final repository = widget.repository;
    if (repository is SupabaseAdminApi &&
        (repository.client.auth.currentUser?.id != _actor ||
            (repository.sessionIdForPortraitReuse ??
                    repository.client.auth.currentSession?.accessToken) !=
                _session)) {
      throw const AdminException('sign_in_required');
    }
  }

  void _persistDraft(UserProfile draft) {
    _checkActor();
    _journal.saveDraft(
      draft,
      base: _base,
      version: _version,
      avatarPath: _avatarPath,
    );
    if (draft.photo != null) {
      completePlatformPhoto(
        ownerId: _actor,
        destination: PhotoDestination.profile,
        targetId: _photoTarget,
        photo: draft.photo!,
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _actor = widget.repository.userId;
    final repository = widget.repository;
    if (repository is SupabaseAdminApi) {
      _session =
          repository.sessionIdForPortraitReuse ??
          repository.client.auth.currentSession?.accessToken;
    }
    _journal = ManagedProfileWriteJournal(_actor, widget.profile?.id);
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _checkActor();
      _journal.load();
      _pending = _journal.pending;
      final profile = widget.profile;
      // Recovery does not depend on downloading the old portrait again.
      final restored = _journal.draft;
      final photo = restored != null || profile == null
          ? null
          : await widget.repository.photo(profile);
      _checkActor();
      if (!mounted) return;
      _base = _journal.base ?? profile?.draft(photo) ?? UserProfile.empty;
      _version = restored != null ? _journal.version : profile?.updatedAt;
      _avatarPath = restored != null
          ? _journal.avatarPath
          : profile?.avatarPath;
      final controller = ProfileController(
        _DraftStore(restored ?? _base, _persistDraft),
      );
      await controller.load();
      final recoveredPhoto = _pending != null
          ? null
          : pendingPlatformPhoto(
              ownerId: _actor,
              destination: PhotoDestination.profile,
              targetId: _photoTarget,
            );
      if (recoveredPhoto != null) {
        controller.updatePhoto(recoveredPhoto);
        await controller.flush();
      }
      if (!mounted) {
        controller.dispose();
        return;
      }
      _controller?.dispose();
      setState(() {
        _controller = controller;
        _busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not load the profile. Please retry.';
        });
      }
    }
  }

  Future<void> _save() async {
    final controller = _controller;
    if (controller == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _checkActor();
      if (!_journal.isCurrent) throw const ManagedProfileDraftChanged();
      await controller.flush();
      if (!mounted) return;
      if (!_journal.isCurrent) throw const ManagedProfileDraftChanged();
      if (controller.hasUnsavedChanges || controller.error != null) {
        throw StateError('Could not persist the local draft.');
      }
      var draft = controller.profile;
      if (_pending == null) {
        if (draft.name.trim().isEmpty ||
            draft.summary.trim().isEmpty ||
            draft.skills.isEmpty) {
          setState(() {
            _error = 'Enter a name, summary and at least one offered skill.';
          });
          return;
        }
        // A rejected version can be edited again. Reconcile against the current
        // server snapshot before assigning a new operation ID.
        if (widget.profile != null) {
          final access = await widget.repository.context();
          _checkActor();
          final remoteProfile = access.profiles
              .where((p) => p.id == widget.profile!.id && p.canManage)
              .firstOrNull;
          if (remoteProfile == null) {
            throw const AdminException('managed_profile_forbidden');
          }
          if (remoteProfile.updatedAt != _version) {
            final remote = remoteProfile.draft(
              await widget.repository.photo(remoteProfile),
            );
            _checkActor();
            if (!mounted) return;
            final conflicts = draft.conflictsWith(_base, remote);
            bool? keep = true;
            if (conflicts.isNotEmpty) {
              keep = await reviewProfileSnapshots(
                context,
                fields: conflicts,
                saved: remote,
                local: draft,
              );
              _checkActor();
              if (!mounted || keep == null) return;
            }
            draft = draft.rebase(
              _base,
              remote,
              useRemote: keep == false ? conflicts : {},
            );
            _base = remote;
            _version = remoteProfile.updatedAt;
            _avatarPath = remoteProfile.avatarPath;
            final replacement = ProfileController(
              _DraftStore(draft, _persistDraft),
            );
            await replacement.load();
            if (!mounted) {
              replacement.dispose();
              return;
            }
            _controller!.dispose();
            _controller = replacement;
          }
        }
        _persistDraft(draft);
        _pending = _journal.prepare({
          'action': 'save',
          'create': widget.profile == null,
          'profile_id': ?widget.profile?.id,
          'expected_updated_at': ?_version,
          'client_operation_id': newChatOperationId(),
          'profile': {
            'name': draft.name,
            'occupation': draft.occupation,
            'summary': draft.summary,
            'skills': draft.skills,
            'searching_skills': draft.searchingSkills,
            'avatar_path': draft.photo == null ? null : _avatarPath,
          },
          'photo_base64': ?(draft.photo == null
              ? null
              : base64Encode(draft.photo!)),
        });
      }
      _checkActor();
      await widget.repository.command(
        jsonDecode(jsonEncode(_pending!)) as Map<String, dynamic>,
      );
      _checkActor();
      _journal.complete(_pending!['client_operation_id'] as String);
      _pending = null;
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      // These codes prove the command was not committed. Keep the editable draft,
      // allowing corrected input or a fresh three-way version reconciliation.
      if (error is AdminException &&
          const {
            'invalid_profile',
            'invalid_request',
            'profile_version_conflict',
          }.contains(error.code) &&
          _pending != null) {
        try {
          _journal.reject(_pending!['client_operation_id'] as String);
          _pending = null;
        } catch (_) {
          // A failed local commit must retain the exact uncertain operation.
        }
      }
      if (mounted) {
        setState(() {
          _error =
              error is AdminException || error is ManagedProfileDraftChanged
              ? error.toString()
              : 'Could not save the profile. Retry the same request.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Profile',
    action: widget.profile == null
        ? null
        : IconButton(
            tooltip: 'Return to my profile',
            onPressed: _busy || _pending != null
                ? null
                : () =>
                      Navigator.of(context).popUntil((route) => route.isFirst),
            icon: const Icon(Icons.person_outline, color: Color(0xFF14679E)),
          ),
    child: _controller == null
        ? Center(
            child: _busy
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error ?? ''),
                      TextButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
          )
        : Column(
            children: [
              if (widget.profile != null)
                ManagedProfileHeader(
                  repository: widget.repository,
                  profile: widget.profile!,
                ),
              Expanded(
                child: AbsorbPointer(
                  absorbing: _busy || _pending != null,
                  child: ProfileEditor(
                    controller: _controller!,
                    occupationRequired: false,
                    pickPhoto: () async {
                      _checkActor();
                      final photo = await pickPlatformPhoto(
                        ownerId: _actor,
                        destination: PhotoDestination.profile,
                        targetId: _photoTarget,
                      );
                      _checkActor();
                      return photo;
                    },
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(20),
                child: FilledButton(
                  onPressed: _busy ? null : _save,
                  child: Text(
                    _busy
                        ? 'Saving…'
                        : _pending != null
                        ? 'Retry save'
                        : 'Save',
                  ),
                ),
              ),
            ],
          ),
  );

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }
}

/// Existing profile controls edit this isolated draft. Only Save sends a
/// privileged command, so Cancel never creates or partially updates a profile.
class _DraftStore implements ProfileStore {
  _DraftStore(this.profile, this.persist);
  UserProfile profile;
  final void Function(UserProfile) persist;
  @override
  Future<UserProfile> read() async => profile;
  @override
  Future<void> write(UserProfile value) async {
    persist(value);
    profile = value;
  }

  @override
  Future<void> clear() async {
    profile = UserProfile.empty;
  }
}
