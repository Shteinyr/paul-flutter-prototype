import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import 'chat_api.dart';
import 'chat_controller.dart';

const _blue = Color(0xFF14679E);

class LiveChatView extends StatefulWidget {
  const LiveChatView({
    super.key,
    required this.controller,
    required this.conversationId,
    required this.peer,
    required this.ownAvatar,
    required this.peerAvatar,
    this.canSend = true,
    this.replyingAs,
    this.onInvite,
  });
  final LiveChatController controller;
  final String conversationId;
  final ChatPeer peer;
  final Widget ownAvatar;
  final Widget peerAvatar;
  final bool canSend;
  final String? replyingAs;
  final VoidCallback? onInvite;

  @override
  State<LiveChatView> createState() => _LiveChatViewState();
}

class _LiveChatViewState extends State<LiveChatView> {
  late final TextEditingController _draft;
  final _scroll = ScrollController();
  final _focus = FocusNode();
  String? _validation;

  bool get _identityValid =>
      widget.controller.repository.currentUserId == widget.controller.userId;
  bool get _ready =>
      _identityValid &&
      widget.canSend &&
      widget.controller.canSend &&
      widget.controller.loaded &&
      !widget.controller.stateLoadFailed;

  @override
  void initState() {
    super.initState();
    _draft = TextEditingController(
      text: widget.controller.draft(widget.conversationId),
    );
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(LiveChatView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.conversationId != widget.conversationId) {
      oldWidget.controller.removeListener(_changed);
      if (oldWidget.controller.activeConversationId ==
          oldWidget.conversationId) {
        oldWidget.controller.closeConversation();
      }
      _draft.text = widget.controller.draft(widget.conversationId);
      _validation = null;
      widget.controller.addListener(_changed);
    }
  }

  void _changed() {
    if (!mounted) return;
    final text = widget.controller.draft(widget.conversationId);
    if (_draft.text != text) {
      _draft.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    setState(() {});
  }

  void _send() {
    if (!_ready || _draft.text.trim().isEmpty) return;
    final text = _draft.text;
    if (text.characters.length > 2000 ||
        utf8.encode(text).length > 65536 ||
        text.contains('\u0000')) {
      setState(
        () => _validation =
            'Use up to 2000 characters within 64 KiB, without null characters.',
      );
      return;
    }
    setState(() => _validation = null);
    unawaited(widget.controller.send(widget.conversationId, text));
    _focus.requestFocus();
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_identityValid) {
      return const ProfilePage(
        title: 'Chat',
        child: Center(child: Text('Please sign in again to continue.')),
      );
    }
    final controller = widget.controller;
    final id = widget.conversationId;
    final messages = controller.messages(id);
    final pending = controller.pending(id);
    final count = messages.length + pending.length;
    return ProfilePage(
      title: widget.peer.name,
      child: Column(
        children: [
          if (widget.replyingAs != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Text(
                'Replying as ${widget.replyingAs}',
                style: const TextStyle(fontSize: 12, color: _blue),
              ),
            ),
          if (!widget.canSend || !controller.canSend)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Profile disabled', style: TextStyle(fontSize: 12)),
            ),
          if (controller.error != null || _validation != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _validation ?? controller.error!,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  if (controller.lastSendErrorCode ==
                          'new_contact_limit_reached' &&
                      widget.onInvite != null)
                    TextButton(
                      onPressed: widget.onInvite,
                      child: const Text('Invite friends'),
                    )
                  else if (controller.error != null)
                    TextButton(
                      onPressed: controller.stateLoadFailed
                          ? controller.load
                          : controller.refresh,
                      child: const Text('Retry chat'),
                    ),
                ],
              ),
            ),
          Expanded(
            child: controller.loadingHistory && count == 0
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : count == 0
                ? const Center(
                    child: Text(
                      'Start a conversation',
                      style: TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  )
                : ListView.builder(
                    key: const Key('live-chat-messages'),
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                    itemCount: count + (controller.hasOlder(id) ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index == count) {
                        return TextButton(
                          key: const Key('load-older-chat'),
                          onPressed: controller.loadingOlder
                              ? null
                              : controller.loadOlder,
                          child: Text(
                            controller.loadingOlder
                                ? 'Loading earlier messages…'
                                : 'Load earlier messages',
                          ),
                        );
                      }
                      if (index < pending.length) {
                        final item = pending[pending.length - 1 - index];
                        final failed = item.delivery == ChatDelivery.failed;
                        return _MessageBubble(
                          key: ValueKey('pending:${item.clientMessageId}'),
                          text: item.text,
                          outgoing: true,
                          avatar: widget.ownAvatar,
                          status: failed ? 'Not sent' : 'Sending…',
                          onRetry: failed
                              ? () => controller.retry(id, item.clientMessageId)
                              : null,
                        );
                      }
                      final item =
                          messages[messages.length -
                              1 -
                              (index - pending.length)];
                      final outgoing =
                          item.senderId == controller.senderProfileId;
                      return _MessageBubble(
                        key: ValueKey('message:${item.id}'),
                        text: item.text,
                        outgoing: outgoing,
                        avatar: outgoing ? widget.ownAvatar : widget.peerAvatar,
                        status: outgoing ? 'Sent' : null,
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 16, 24),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('live-chat-message-field'),
                    controller: _draft,
                    focusNode: _focus,
                    enabled: _ready,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    textInputAction: TextInputAction.send,
                    onChanged: (text) {
                      _validation = null;
                      controller.updateDraft(id, text);
                    },
                    onSubmitted: (_) => _send(),
                    style: const TextStyle(fontSize: 13, height: 1.5),
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      counterText: '',
                      border: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0x2214679E)),
                      ),
                      enabledBorder: UnderlineInputBorder(
                        borderSide: BorderSide(color: Color(0x2214679E)),
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _draft,
                  builder: (context, value, _) {
                    final sendingSameText = pending.any(
                      (item) =>
                          item.text == value.text &&
                          item.delivery == ChatDelivery.pending,
                    );
                    return IconButton(
                      key: const Key('send-live-chat-message'),
                      tooltip: 'Send message',
                      color: _blue,
                      onPressed:
                          !_ready ||
                              value.text.trim().isEmpty ||
                              sendingSameText
                          ? null
                          : _send,
                      icon: const Icon(Icons.send_outlined, size: 23),
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    if (widget.controller.activeConversationId == widget.conversationId) {
      widget.controller.closeConversation();
    }
    unawaited(widget.controller.flushDrafts());
    _draft.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.text,
    required this.outgoing,
    required this.avatar,
    this.status,
    this.onRetry,
  });
  final String text;
  final bool outgoing;
  final Widget avatar;
  final String? status;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: outgoing ? null : _blue,
          border: outgoing ? Border.all(color: const Color(0x2214679E)) : null,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: outgoing ? Colors.black : Colors.white,
              ),
            ),
            if (status != null)
              Text(
                status!,
                style: const TextStyle(fontSize: 10, color: Colors.black54),
              ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                child: const Text('Retry message'),
              ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        label: outgoing
            ? '${status ?? 'Outgoing'} message'
            : 'Received message',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: outgoing
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: outgoing
              ? [bubble, const SizedBox(width: 14), avatar]
              : [avatar, const SizedBox(width: 14), bubble],
        ),
      ),
    );
  }
}
