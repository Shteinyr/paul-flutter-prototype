import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../app.dart';
import '../live/chat_api.dart';
import '../profile/profile_controller.dart';
import '../profile/profile_store.dart';
import '../profile/public_profile_view.dart';
import '../profile/user_profile.dart';
import 'admin_api.dart';

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

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final profile = widget.profile;
      final photo = profile == null
          ? null
          : await widget.repository.photo(profile);
      if (!mounted) return;
      final controller = ProfileController(
        _DraftStore(profile?.draft(photo) ?? UserProfile.empty),
      );
      await controller.load();
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
    await controller.flush();
    if (!mounted) return;
    final draft = controller.profile;
    if (_pending == null &&
        (draft.name.trim().isEmpty ||
            draft.summary.trim().isEmpty ||
            draft.skills.isEmpty)) {
      setState(() {
        _error = 'Enter a name, summary and at least one offered skill.';
      });
      return;
    }
    // A failed or lost response is retried with the exact original operation.
    _pending ??= {
      'action': 'save',
      'create': widget.profile == null,
      'profile_id': ?widget.profile?.id,
      'expected_updated_at': ?widget.profile?.updatedAt,
      'client_operation_id': newChatOperationId(),
      'profile': {
        'name': draft.name,
        'occupation': draft.occupation,
        'summary': draft.summary,
        'skills': draft.skills,
        'searching_skills': draft.searchingSkills,
        'avatar_path': widget.profile?.avatarPath,
      },
      'photo_base64': ?(draft.photo == null
          ? null
          : base64Encode(draft.photo!)),
    };
    // Removing a photo is an explicit null, while unchanged photos are retained.
    if (draft.photo == null) {
      (_pending!['profile'] as Map)['avatar_path'] = null;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.repository.command(_pending!);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is AdminException
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
    title: widget.profile == null ? 'Create user' : 'Edit user',
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
              Expanded(
                child: AbsorbPointer(
                  absorbing: _busy || _pending != null,
                  child: ProfileEditor(
                    controller: _controller!,
                    occupationRequired: false,
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
  _DraftStore(this.profile);
  UserProfile profile;
  @override
  Future<UserProfile> read() async => profile;
  @override
  Future<void> write(UserProfile value) async {
    profile = value;
  }

  @override
  Future<void> clear() async {
    profile = UserProfile.empty;
  }
}
