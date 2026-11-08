import 'dart:async';

import 'package:flutter/material.dart';

import '../demo_contacts.dart';
import '../profile/public_profile_view.dart';
import 'demo_chat_controller.dart';

const _blue = Color(0xFF14679E);

class DemoChatView extends StatefulWidget {
  const DemoChatView({
    super.key,
    required this.contact,
    required this.controller,
    required this.ownAvatar,
  });
  final DemoContact contact;
  final DemoChatController controller;
  final Widget ownAvatar;
  @override
  State<DemoChatView> createState() => _DemoChatViewState();
}

class _DemoChatViewState extends State<DemoChatView> {
  late final TextEditingController _draft;
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.open(widget.contact.id);
    _draft = TextEditingController(
      text: widget.controller.ensureConversation(widget.contact.id).draft,
    );
  }

  void _send() {
    if (!widget.controller.send(widget.contact.id, _draft.text)) return;
    _draft.clear();
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
  Widget build(BuildContext context) => ProfilePage(
    title: widget.contact.name,
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final messages = widget.controller
            .ensureConversation(widget.contact.id)
            .messages;
        return Column(
          children: [
            if (widget.controller.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.controller.error!,
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    TextButton(
                      onPressed: widget.controller.flush,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Text(
                        'Start a conversation',
                        style: TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    )
                  : ListView.builder(
                      key: const Key('chat-messages'),
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final message = messages[messages.length - 1 - index];
                        final bubble = Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: message.outgoing ? null : _blue,
                              border: message.outgoing
                                  ? Border.all(color: const Color(0x2214679E))
                                  : null,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child: Text(
                              message.text,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.5,
                                color: message.outgoing
                                    ? Colors.black
                                    : Colors.white,
                              ),
                            ),
                          ),
                        );
                        final avatar = message.outgoing
                            ? widget.ownAvatar
                            : ClipOval(
                                child: Image.asset(
                                  widget.contact.photoAsset,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                ),
                              );
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Semantics(
                            label: message.outgoing
                                ? 'Sent message'
                                : 'Message from ${widget.contact.name}',
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisAlignment: message.outgoing
                                  ? MainAxisAlignment.end
                                  : MainAxisAlignment.start,
                              children: message.outgoing
                                  ? [bubble, const SizedBox(width: 14), avatar]
                                  : [avatar, const SizedBox(width: 14), bubble],
                            ),
                          ),
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
                      key: const Key('chat-message-field'),
                      controller: _draft,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 2000,
                      textCapitalization: TextCapitalization.sentences,
                      textInputAction: TextInputAction.send,
                      onChanged: (text) => widget.controller.updateDraft(
                        widget.contact.id,
                        text,
                      ),
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
                    builder: (context, value, _) => IconButton(
                      key: const Key('send-chat-message'),
                      tooltip: 'Send demo message',
                      color: _blue,
                      onPressed: value.text.trim().isEmpty ? null : _send,
                      icon: const Icon(Icons.send_outlined, size: 23),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );

  @override
  void dispose() {
    widget.controller.close(widget.contact.id);
    unawaited(widget.controller.flush());
    _draft.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }
}
