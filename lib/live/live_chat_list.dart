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
  });
  final LiveChatController controller;
  final ValueChanged<ChatSummary> onOpen;
  final Widget Function(ChatPeer peer) avatarFor;

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
          if (!controller.loaded && !controller.stateLoadFailed)
            const Expanded(
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (controller.conversations.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'Open a contact’s profile to start a conversation.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.black54),
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
                        name: thread.peer.name,
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
