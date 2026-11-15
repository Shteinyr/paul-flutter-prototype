import 'package:flutter/material.dart';

import '../app.dart' show ProfileAvatar;
import 'profile_controller.dart';
import 'user_profile.dart';

/// The user reviews a fixed pair of snapshots before choosing which edits to keep.
Future<void> reviewProfileConflict(
  BuildContext context,
  ProfileController controller,
) async {
  final fields = controller.conflictingFields;
  final saved = controller.savedProfile, local = controller.profile;
  final keep = await reviewProfileSnapshots(
    context,
    fields: fields,
    saved: saved,
    local: local,
  );
  // A lifecycle refresh may have changed either snapshot while the dialog was open.
  if (keep != null &&
      identical(saved, controller.savedProfile) &&
      identical(local, controller.profile)) {
    await controller.resolveConflict(keepLocal: keep);
  }
}

Future<bool?> reviewProfileSnapshots(
  BuildContext context, {
  required Set<String> fields,
  required UserProfile saved,
  required UserProfile local,
}) async {
  const labels = {
    'name': 'Name',
    'occupation': 'Occupation',
    'summary': 'Summary',
    'skills': 'Offered skills',
    'searching_skills': 'Searching skills',
    'photo': 'Photo',
  };
  String text(Object? value) =>
      value is List ? value.join(', ') : value?.toString() ?? 'None';
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Review profile changes'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'These fields changed on another device. Choose which values to save. Other edits will be kept.',
            ),
            const SizedBox(height: 20),
            for (final key in fields)
              Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      labels[key]!,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    if (key == 'photo')
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                const Text('Your edit'),
                                const SizedBox(height: 8),
                                ProfileAvatar(photo: local.photo, size: 64),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              children: [
                                const Text('Saved'),
                                const SizedBox(height: 8),
                                ProfileAvatar(photo: saved.photo, size: 64),
                              ],
                            ),
                          ),
                        ],
                      )
                    else ...[
                      Text('Your edit: ${text(local.editableFields[key])}'),
                      const SizedBox(height: 6),
                      Text('Saved: ${text(saved.editableFields[key])}'),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Use saved values'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Keep my edits'),
        ),
      ],
    ),
  );
}
