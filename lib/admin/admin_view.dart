import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import 'admin_api.dart';
import 'managed_profile_editor.dart';
import 'managed_profile_workspace.dart';
import 'managed_profile_header.dart';
import '../live/chat_api.dart';

Future<AdminAccess> _loadAccess(AdminRepository repository) {
  final future = Future<AdminAccess>.sync(repository.context);
  // Route-return refreshes can finish before FutureBuilder subscribes or after
  // its route is removed. Handle errors now and retain the result for the UI.
  future.ignore();
  return future;
}

/// Each mount belongs to the host's current Auth identity. The repository pins
/// that identity and the screen rechecks server access when it is opened.
class AdminEntry extends StatefulWidget {
  const AdminEntry({super.key, required this.repository, this.onDeleteProfile});
  final AdminRepository repository;
  final Future<void> Function(ManagedProfile)? onDeleteProfile;
  @override
  State<AdminEntry> createState() => _AdminEntryState();
}

class _AdminEntryState extends State<AdminEntry> {
  late Future<AdminAccess> _access;
  @override
  void initState() {
    super.initState();
    _access = _loadAccess(widget.repository);
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
            _access = _loadAccess(widget.repository);
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
              builder: (_) => AdminView(
                repository: widget.repository,
                onDeleteProfile: widget.onDeleteProfile,
              ),
            ),
          );
          if (mounted) {
            setState(() {
              _access = _loadAccess(widget.repository);
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
  const AdminView({super.key, required this.repository, this.onDeleteProfile});
  final AdminRepository repository;
  final Future<void> Function(ManagedProfile)? onDeleteProfile;
  @override
  State<AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<AdminView> {
  late AdminRepository _repository;
  String? _portraitSession;
  late Future<AdminAccess> _access;
  @override
  void initState() {
    super.initState();
    _useRepository(widget.repository);
  }

  void _useRepository(AdminRepository repository) {
    _repository = repository;
    _portraitSession = repository is SupabaseAdminApi
        ? repository.sessionIdForPortraitReuse
        : null;
    _access = _loadAccess(repository);
  }

  @override
  void didUpdateWidget(AdminView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.repository;
    final current = _repository;
    final sameContext = current is SupabaseAdminApi && next is SupabaseAdminApi
        ? identical(current.client, next.client) &&
              current.userId == next.userId &&
              _portraitSession != null &&
              _portraitSession == next.sessionIdForPortraitReuse
        : identical(current, next);
    if (sameContext) return;
    _useRepository(next);
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && route != null) {
        Navigator.of(context).popUntil((candidate) => candidate == route);
      }
    });
  }

  Future<void> _edit([ManagedProfile? profile]) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            ManagedProfileEditor(repository: _repository, profile: profile),
      ),
    );
    if (mounted) {
      setState(() {
        _access = _loadAccess(_repository);
      });
    }
  }

  Future<void> _inbox(ManagedProfile profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ManagedProfileWorkspace(
          repository: _repository,
          profileId: profile.id,
          onDeleteProfile: widget.onDeleteProfile,
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _access = _loadAccess(_repository);
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
                          await _repository.command(command);
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
        _access = _loadAccess(_repository);
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
                      _access = _loadAccess(_repository);
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
            final future = _loadAccess(_repository);
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
                  key: ValueKey('managed-row-${profile.id}'),
                  contentPadding: EdgeInsets.zero,
                  onTap: () => _inbox(profile),
                  minVerticalPadding: 16,
                  minTileHeight: 100,
                  horizontalTitleGap: 21,
                  leading: ManagedProfileAvatar(
                    repository: _repository,
                    profile: profile,
                    size: 65,
                  ),
                  title: Text(
                    profile.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'User actions',
                    onSelected: (action) {
                      if (action == 'inbox') _inbox(profile);
                      if (action == 'edit') _edit(profile);
                      if (action == 'status') _status(profile);
                    },
                    itemBuilder: (_) => [
                      if (profile.canReply)
                        const PopupMenuItem(
                          value: 'inbox',
                          child: Text('Open inbox'),
                        ),
                      if (profile.canManage) ...[
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('Edit user'),
                        ),
                        PopupMenuItem(
                          value: 'status',
                          child: Text(
                            profile.disabledAt == null
                                ? 'Disable user'
                                : 'Restore user',
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
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
                      if (profile.disabledAt != null)
                        const Text(
                          'Disabled',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFFFF645C),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
