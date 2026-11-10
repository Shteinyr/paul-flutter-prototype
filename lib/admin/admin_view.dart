import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import 'admin_api.dart';
import 'managed_profile_editor.dart';
import 'operator_inbox_view.dart';
import '../live/chat_api.dart';

/// Each mount belongs to the host's current Auth identity. The repository pins
/// that identity and the screen rechecks server access when it is opened.
class AdminEntry extends StatefulWidget {
  const AdminEntry({super.key, required this.repository});
  final AdminRepository repository;
  @override
  State<AdminEntry> createState() => _AdminEntryState();
}

class _AdminEntryState extends State<AdminEntry> {
  late Future<AdminAccess> _access;
  @override
  void initState() {
    super.initState();
    _access = widget.repository.context();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AdminAccess>(
    future: _access,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        final error = snapshot.error;
        if (error is AdminException &&
            (error.code == 'admin_forbidden' ||
                error.code == 'sign_in_required')) {
          return const SizedBox.shrink();
        }
        return TextButton(
          onPressed: () => setState(() {
            _access = widget.repository.context();
          }),
          child: const Text('Retry Admin access'),
        );
      }
      if (!snapshot.hasData) return const SizedBox.shrink();
      return TextButton(
        key: const Key('admin-entry'),
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AdminView(repository: widget.repository),
            ),
          );
          if (mounted) {
            setState(() {
              _access = widget.repository.context();
            });
          }
        },
        child: const Text(
          'Admin',
          style: TextStyle(
            fontSize: 12,
            letterSpacing: .5,
            color: Color(0xFFFF645C),
          ),
        ),
      );
    },
  );
}

class AdminView extends StatefulWidget {
  const AdminView({super.key, required this.repository});
  final AdminRepository repository;
  @override
  State<AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<AdminView> {
  late Future<AdminAccess> _access;
  @override
  void initState() {
    super.initState();
    _access = widget.repository.context();
  }

  Future<void> _edit([ManagedProfile? profile]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ManagedProfileEditor(
          repository: widget.repository,
          profile: profile,
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _access = widget.repository.context();
      });
    }
  }

  Future<void> _inbox(ManagedProfile profile) async {
    final repository = widget.repository.operatorFor(profile.id);
    final actorId = widget.repository.userId;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OperatorInboxView(
          repository: repository,
          actorId: actorId,
          profile: profile,
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _access = widget.repository.context();
      });
    }
  }

  Future<void> _status(ManagedProfile profile) async {
    final enabled = profile.disabledAt != null;
    final command = <String, dynamic>{
      'action': 'status',
      'profile_id': profile.id,
      'enabled': enabled,
      'client_operation_id': newChatOperationId(),
      'expected_updated_at': profile.updatedAt,
    };
    bool busy = false;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(enabled ? 'Restore user?' : 'Disable user?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(profile.name),
                if (error != null)
                  Text(error!, style: const TextStyle(fontSize: 12)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        update(() {
                          busy = true;
                          error = null;
                        });
                        try {
                          await widget.repository.command(command);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (failure) {
                          if (dialogContext.mounted) {
                            update(() {
                              busy = false;
                              error = failure is AdminException
                                  ? failure.toString()
                                  : 'Could not update this profile. Please retry.';
                            });
                          }
                        }
                      },
                child: Text(
                  busy
                      ? 'Saving…'
                      : enabled
                      ? 'Restore'
                      : 'Disable',
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _access = widget.repository.context();
      });
    }
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Admin',
    child: FutureBuilder<AdminAccess>(
      future: _access,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    snapshot.error is AdminException
                        ? snapshot.error.toString()
                        : const AdminException('server_unavailable').toString(),
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      _access = widget.repository.context();
                    }),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        final access = snapshot.requireData;
        return RefreshIndicator(
          onRefresh: () async {
            final future = widget.repository.context();
            setState(() {
              _access = future;
            });
            try {
              await future;
            } catch (_) {
              /* Render the server error above. */
            }
          },
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(37.5, 36, 37.5, 40),
            children: [
              const Text(
                'User management',
                style: TextStyle(fontSize: 20, color: Color(0xFF14679E)),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _edit,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Create user'),
                ),
              ),
              const SizedBox(height: 20),
              if (access.profiles.isEmpty) const Text('No assigned profiles.'),
              for (final profile in access.profiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(profile.name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (profile.canReply)
                        IconButton(
                          tooltip: 'Open inbox',
                          onPressed: () => _inbox(profile),
                          icon: const Icon(Icons.chat_bubble_outline, size: 20),
                        ),
                      if (profile.canManage) ...[
                        IconButton(
                          tooltip: 'Edit user',
                          onPressed: () => _edit(profile),
                          icon: const Icon(Icons.edit_outlined, size: 20),
                        ),
                        IconButton(
                          tooltip: profile.disabledAt == null
                              ? 'Disable user'
                              : 'Restore user',
                          onPressed: () => _status(profile),
                          icon: Icon(
                            profile.disabledAt == null
                                ? Icons.pause_circle_outline
                                : Icons.play_circle_outline,
                            size: 20,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    profile.disabledAt == null ? 'Active' : 'Disabled',
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
