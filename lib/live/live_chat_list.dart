import 'package:flutter/material.dart';

import '../app.dart';
import 'chat_api.dart';
import 'chat_controller.dart';

class LiveChatList extends StatelessWidget {
  const LiveChatList({
    super.key,
    required this.controller,
    required this.onOpen,
    required this.avatarFor,
    this.emptyText = 'Open a contact’s profile to start a conversation.',
  });
  final LiveChatController controller;
  final ValueChanged<ChatSummary> onOpen;
  final Widget Function(ChatPeer peer) avatarFor;
  final String emptyText;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (controller.repository.currentUserId != controller.userId) {
        return const Center(child: Text('Please sign in again to continue.'));
      }
      return Column(
        children: [
          if (controller.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      controller.error!,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: controller.stateLoadFailed
                        ? controller.load
                        : controller.refresh,
                    child: const Text('Retry chats'),
                  ),
                ],
              ),
            ),
          if (controller.conversations.isEmpty &&
              !controller.conversationsLoaded)
            Expanded(
              child: controller.error == null && !controller.stateLoadFailed
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const SizedBox.shrink(),
            )
          else if (controller.conversations.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: Text(
                    emptyText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: RefreshIndicator(
                onRefresh: controller.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(37.5, 47, 37.5, 24),
                  children: [
                    for (final thread in controller.conversations)
                      ContactRow(
                        key: ValueKey(thread.id),
                        name: thread.peer.displayName,
                        occupation: thread.peer.occupation,
                        avatar: avatarFor(thread.peer),
                        unread: thread.unread,
                        onOpen: () => onOpen(thread),
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
