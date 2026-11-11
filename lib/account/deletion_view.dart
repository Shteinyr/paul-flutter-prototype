import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import 'deletion.dart';

Future<bool> confirmProfileDeletion(
  BuildContext context, {
  String? name,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          name == null ? 'Delete your account?' : 'Delete this user?',
        ),
        content: Text(
          '${name == null ? 'Your' : '$name’s'} photo, description, skills and connections will be removed. '
          'Existing conversations remain with the name “Deleted user”. This action is permanent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete permanently'),
          ),
        ],
      ),
    ) ==
    true;

class DeletionStatusView extends StatelessWidget {
  const DeletionStatusView({
    super.key,
    required this.controller,
    required this.record,
    this.onDone,
    this.onSignIn,
  });
  final DeletionController controller;
  final DeletionRecord record;
  final VoidCallback? onDone;
  final VoidCallback? onSignIn;
  @override
  Widget build(BuildContext context) => ProfilePage(
    title: record.self ? 'Account deletion' : 'User deletion',
    child: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final complete = controller.complete(record);
        return ListView(
          padding: const EdgeInsets.all(32),
          children: [
            Text(
              controller.rejected(record)
                  ? 'Refresh the profile before deleting.'
                  : complete
                  ? record.self
                        ? 'Account deleted'
                        : 'User deleted'
                  : controller.confirmed(record)
                  ? 'Profile removed. Finishing account and photo cleanup…'
                  : 'Confirming deletion…',
              textAlign: TextAlign.center,
            ),
            if (controller.busy(record))
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (controller.errors[record.operationId] case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Text(error, textAlign: TextAlign.center),
              ),
            if (!controller.finished(record))
              TextButton(
                onPressed: controller.busy(record)
                    ? null
                    : () {
                        if (controller.repository.currentUserId ==
                                record.actorId &&
                            !controller.confirmed(record)) {
                          controller.retry(record);
                        } else {
                          controller.refresh(record);
                        }
                      },
                child: const Text('Check deletion status'),
              ),
            if (record.self &&
                !controller.confirmed(record) &&
                controller.repository.currentUserId == null &&
                onSignIn != null)
              TextButton(
                onPressed: controller.busy(record) ? null : onSignIn,
                child: const Text('Sign in to retry deletion'),
              ),
            if (controller.finished(record))
              TextButton(
                onPressed: () {
                  controller.dismiss(record);
                  onDone?.call();
                },
                child: const Text('Done'),
              ),
          ],
        );
      },
    ),
  );
}
