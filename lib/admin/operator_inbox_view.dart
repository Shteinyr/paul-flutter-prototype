import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../live/chat_api.dart';
import '../live/chat_controller.dart';
import '../live/live_chat_list.dart';
import '../live/live_chat_view.dart';
import '../profile/public_profile_view.dart';
import 'admin_api.dart';
import 'operator_chat_api.dart';

class OperatorInboxView extends StatefulWidget {
  const OperatorInboxView({
    super.key,
    required this.repository,
    required this.actorId,
    required this.profile,
    this.initialConversationId,
    this.embedded = false,
  });
  final ChatRepository repository;
  final String actorId;
  final ManagedProfile profile;
  final String? initialConversationId;
  final bool embedded;
  @override
  State<OperatorInboxView> createState() => _OperatorInboxViewState();
}

class _OperatorInboxViewState extends State<OperatorInboxView>
    with WidgetsBindingObserver {
  late final LiveChatController _chat;
  late final ChatRepository _repository;
  bool _opening = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _repository = widget.repository;
    final repository = _repository;
    if (repository is OperatorChatApi) {
      repository.disabled = widget.profile.disabledAt != null;
    }
    _chat = LiveChatController(
      repository,
      widget.actorId,
      senderProfileId: widget.profile.id,
      canSend: () => repository is OperatorChatApi
          ? !repository.disabled
          : widget.profile.disabledAt == null,
      drafts: OperatorChatStateStore(widget.profile.id),
    );
    unawaited(_loadInbox());
  }

  Future<void> _loadInbox() async {
    await _chat.load();
    if (!mounted || _repository.currentUserId != widget.actorId) return;
    final id = widget.initialConversationId;
    if (id == null) return;
    final thread = _chat.conversations
        .where((thread) => thread.id == id)
        .firstOrNull;
    if (thread != null) await _open(thread);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _chat.resume();
    } else {
      _chat.pause();
      unawaited(_chat.flushDrafts());
    }
  }

  Future<void> _open(ChatSummary thread) async {
    if (_opening) return;
    _opening = true;
    try {
      await _chat.openConversation(thread.id);
      if (!mounted || _repository.currentUserId != widget.actorId) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LiveChatView(
            controller: _chat,
            conversationId: thread.id,
            peer: thread.peer,
            ownAvatar: const ProfileAvatar(size: 30),
            peerAvatar: const ProfileAvatar(size: 30),
            replyingAs: widget.profile.name,
          ),
        ),
      );
    } finally {
      _chat.closeConversation();
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        if (!widget.embedded)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 8),
            child: Text(
              widget.profile.name,
              style: const TextStyle(fontSize: 15, color: Color(0xFF14679E)),
            ),
          ),
        Expanded(
          child: LiveChatList(
            controller: _chat,
            onOpen: (thread) => unawaited(_open(thread)),
            avatarFor: (_) => const ProfileAvatar(size: 65),
            emptyText: 'No incoming messages yet.',
          ),
        ),
      ],
    );
    return widget.embedded
        ? content
        : ProfilePage(title: 'Inbox', child: content);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_chat.flushDrafts());
    _chat.dispose();
    final repository = _repository;
    if (repository is OperatorChatApi) unawaited(repository.dispose());
    super.dispose();
  }
}

/// Namespace the existing tab-scoped journal by the real actor and managed
/// sender. Normal chat drafts and other managed profiles stay independent.
class OperatorChatStateStore implements ChatStateStore {
  OperatorChatStateStore(this.profileId);
  final String profileId;
  final _store = SessionChatStateStore();
  @override
  Future<String?> read(String userId) =>
      _store.read('admin.$userId.$profileId');
  @override
  Future<void> write(String userId, String state) =>
      _store.write('admin.$userId.$profileId', state);
}
