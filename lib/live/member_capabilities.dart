import 'package:flutter/material.dart';

class MemberCapabilities {
  const MemberCapabilities({
    required this.invitedRegistrations,
    required this.canMessageAnyone,
    required this.canPublishCommunity,
    required this.offeringLimit,
    required this.newConversationsRemaining,
    required this.quotaResetsAt,
  });
  final int invitedRegistrations;
  final bool canMessageAnyone;
  final bool canPublishCommunity;
  final int? offeringLimit;
  final int? newConversationsRemaining;
  final DateTime quotaResetsAt;

  factory MemberCapabilities.fromJson(Map<String, dynamic> value) =>
      MemberCapabilities(
        invitedRegistrations: value['invited_registrations'] as int,
        canMessageAnyone: value['can_message_anyone'] as bool,
        canPublishCommunity: value['can_publish_community'] as bool,
        offeringLimit: value['offering_limit'] as int?,
        newConversationsRemaining: value['new_conversations_remaining'] as int?,
        quotaResetsAt: DateTime.parse(value['quota_resets_at'] as String),
      );
}

class MemberLevelStatus extends StatelessWidget {
  const MemberLevelStatus({
    super.key,
    required this.capabilities,
    required this.error,
    required this.onRefresh,
    required this.onInvite,
  });
  final MemberCapabilities? capabilities;
  final String? error;
  final VoidCallback onRefresh;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final level = capabilities;
    return Column(
      children: [
        if (level != null) ...[
          Text(
            '${level.invitedRegistrations} joined with your invitation',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(
            level.canMessageAnyone
                ? 'Message anyone, anytime'
                : 'Invite 2 people to message anyone, anytime',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
          if (!level.canPublishCommunity)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Invite 10 people to offer more skills and ask our community.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12),
              ),
            ),
        ],
        if (error != null)
          Text(
            error!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12),
          ),
        TextButton(
          onPressed: onRefresh,
          child: Text(
            error == null
                ? 'Refresh invitation level'
                : 'Retry invitation level',
          ),
        ),
        TextButton(onPressed: onInvite, child: const Text('Invite friends')),
      ],
    );
  }
}
