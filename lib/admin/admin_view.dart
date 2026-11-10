import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import 'admin_api.dart';

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
              const SizedBox(height: 28),
              if (access.profiles.isEmpty) const Text('No assigned profiles.'),
              for (final profile in access.profiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(profile.name),
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
