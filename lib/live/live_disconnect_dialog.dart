import 'package:flutter/material.dart';

import 'chat_api.dart';

class LiveDisconnectDialog extends StatefulWidget {
  const LiveDisconnectDialog({
    super.key,
    required this.repository,
    required this.peer,
    required this.userId,
  });
  final ChatRepository repository;
  final ChatPeer peer;
  final String userId;
  @override
  State<LiveDisconnectDialog> createState() => _LiveDisconnectDialogState();
}

class _LiveDisconnectDialogState extends State<LiveDisconnectDialog> {
  final _operationId = newChatOperationId();
  bool _working = false;
  String? _error;

  Future<void> _remove() async {
    if (_working || widget.repository.currentUserId != widget.userId) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await widget.repository.disconnect(widget.peer.id, _operationId);
      if (!mounted ||
          widget.repository.currentUserId != widget.userId ||
          ModalRoute.of(context)?.isCurrent != true) {
        return;
      }
      Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted && widget.repository.currentUserId == widget.userId) {
        setState(
          () => _error =
              'Could not confirm removal. Retry this request or cancel.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Delete connection?'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${widget.peer.name} will be removed from Contacts. Your conversation will remain.',
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: const TextStyle(fontSize: 12)),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('Cancel'),
      ),
      TextButton(
        key: const Key('confirm-live-disconnect'),
        onPressed: _working ? null : _remove,
        style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF645C)),
        child: Text(
          _working
              ? 'Removing…'
              : _error == null
              ? 'Delete'
              : 'Retry removal',
        ),
      ),
    ],
  );
}
