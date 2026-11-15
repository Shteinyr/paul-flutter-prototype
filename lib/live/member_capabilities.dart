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

  // Compatibility while the coordinator removes the old host footer wiring.
  // The source P15 card is opened only by a blocked-action callback.
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
