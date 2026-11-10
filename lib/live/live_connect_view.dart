import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import 'invitation_actions.dart';
import 'invitation_controller.dart';

class LiveConnectView extends StatefulWidget {
  const LiveConnectView({
    super.key,
    required this.invitation,
    required this.appUrl,
    this.actions,
  });

  final InvitationController invitation;
  final Uri appUrl;
  final InvitationActions? actions;

  @override
  State<LiveConnectView> createState() => _LiveConnectViewState();
}

class _LiveConnectViewState extends State<LiveConnectView> {
  late final InvitationActions _actions =
      widget.actions ?? createInvitationActions();

  List<InvitationContact> _contacts = const [];
  bool _picking = false;
  String? _contactStatus;

  Future<void> _pickContacts() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _contactStatus = null;
      _contacts = const [];
    });
    InvitationContactSelection selection;
    try {
      selection = await _actions.pickContacts();
    } catch (_) {
      selection = const InvitationContactSelection(
        InvitationActionResult.failed,
      );
    }
    if (!mounted) return;
    if (!widget.invitation.usable && !widget.invitation.loading) {
      await widget.invitation.refresh();
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      _contacts = selection.result == InvitationActionResult.completed
          ? selection.contacts
          : const [];
      _contactStatus = switch (selection.result) {
        InvitationActionResult.completed =>
          'Selected contacts stay on this screen. Choose a number to invite.',
        InvitationActionResult.cancelled =>
          'Contact selection cancelled. You can use Share or try again.',
        InvitationActionResult.denied =>
          'Contact access was blocked. You can use Share or try again.',
        InvitationActionResult.unavailable =>
          'Contact selection is unavailable in this browser. Use Share to invite someone.',
        InvitationActionResult.failed =>
          'Could not select contacts. You can use Share or try again.',
      };
    });
  }

  void _preview({String? name, String? number}) => showDialog<void>(
    context: context,
    builder: (_) => _InvitationDialog(
      invitation: widget.invitation,
      appUrl: widget.appUrl,
      actions: _actions,
      recipientName: name,
      recipientNumber: number,
    ),
  );

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Connect',
    child: ListenableBuilder(
      listenable: widget.invitation,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(37.5, 36, 37.5, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Hey, let’s connect in Paul.',
                        style: TextStyle(
                          fontSize: 11,
                          height: 2.1,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      const Text(
                        'Open the invitation in your browser.',
                        style: TextStyle(
                          fontSize: 11,
                          height: 2.1,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                      Text(
                        widget.invitation.usable
                            ? 'Use invite code: ${widget.invitation.invitation!.code}'
                            : 'Generating a new invitation…',
                        style: const TextStyle(
                          fontSize: 11,
                          height: 2.1,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: _preview,
                  child: const Text(
                    'Share',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w300),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(color: Color(0x2214679E), height: 1),
            const SizedBox(height: 20),
            if (_actions.canPickContacts)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('pick-invitation-contacts'),
                  onPressed: _picking ? null : _pickContacts,
                  child: Text(
                    _picking ? 'Selecting contacts…' : 'Invite a contact',
                  ),
                ),
              )
            else
              const Text(
                'Contact selection is unavailable in this browser. Use Share to invite someone.',
                style: TextStyle(fontSize: 12, height: 1.7),
              ),
            if (_contactStatus != null)
              Text(
                _contactStatus!,
                key: const Key('invitation-contact-status'),
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
            for (final contact in _contacts) ...[
              const SizedBox(height: 20),
              Text(
                contact.name.isEmpty ? 'Selected contact' : contact.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (contact.phones.isEmpty)
                const Text(
                  'No phone number selected. Use Share to choose a recipient.',
                  style: TextStyle(fontSize: 12),
                ),
              for (final phone in contact.phones)
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        phone,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () =>
                          _preview(name: contact.name, number: phone),
                      child: const Text('Invite'),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _InvitationDialog extends StatefulWidget {
  const _InvitationDialog({
    required this.invitation,
    required this.appUrl,
    required this.actions,
    this.recipientName,
    this.recipientNumber,
  });
  final InvitationController invitation;
  final Uri appUrl;
  final InvitationActions actions;
  final String? recipientName;
  final String? recipientNumber;

  @override
  State<_InvitationDialog> createState() => _InvitationDialogState();
}

class _InvitationDialogState extends State<_InvitationDialog> {
  bool _busy = false;
  String? _status;
  LiveInvitation? _actedOn;
  LiveInvitation? _copied;

  bool get _copyIsCurrent =>
      _copied != null &&
      widget.invitation.usable &&
      _copied!.id == widget.invitation.invitation?.id &&
      _copied!.token == widget.invitation.invitation?.token;

  Future<void> _openSms() async {
    if (_busy || !_copyIsCurrent) return;
    final safe = invitationSmsNumber(widget.recipientNumber ?? '');
    if (safe == null) return;
    setState(() => _busy = true);
    InvitationActionResult result;
    try {
      result = await widget.actions.openSms(safe);
    } catch (_) {
      result = InvitationActionResult.failed;
    }
    if (!mounted) return;
    if (!widget.invitation.usable && !widget.invitation.loading) {
      await widget.invitation.refresh();
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = result == InvitationActionResult.completed
          ? 'Requested SMS app for the selected number. Paste the copied invitation there. If no app opens, use Share.'
          : 'Could not request the SMS app. You can use Share or copy the invitation manually.';
    });
  }

  String _message(LiveInvitation invite) {
    final link = widget.appUrl.replace(fragment: 'invite=${invite.token}');
    return 'Hey, let’s connect in Paul.\n$link\nUse invite code: ${invite.code}\nValid for 15 minutes from generation.';
  }

  Future<void> _perform({required bool sharing}) async {
    if (_busy) return;
    final controller = widget.invitation;
    final current = controller.invitation;
    if (!controller.usable || current == null) {
      await controller.refresh();
      return;
    }
    setState(() {
      _busy = true;
      if (!sharing) _copied = null;
      _status = null;
      _actedOn = current;
    });
    InvitationActionResult result;
    try {
      // Both adapters start synchronously in this deliberate button event.
      result = await (sharing
          ? widget.actions.share(_message(current))
          : widget.actions.copy(_message(current)));
    } catch (_) {
      result = InvitationActionResult.failed;
    }
    if (!mounted) return;
    if (!controller.usable && !controller.loading) await controller.refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!sharing && result == InvitationActionResult.completed) {
        _copied = current;
      }
      _status = switch (result) {
        InvitationActionResult.completed =>
          sharing
              ? 'Share request completed. Confirm delivery in the receiving app.'
              : 'Invitation copied.',
        InvitationActionResult.cancelled =>
          'Sharing cancelled. You can try again or copy the invitation.',
        InvitationActionResult.unavailable =>
          'This browser cannot use this action. Select and copy the invitation manually.',
        InvitationActionResult.denied =>
          'The browser blocked this action. Try again or select and copy the invitation manually.',
        InvitationActionResult.failed =>
          'Could not complete this action. Try again or select and copy the invitation manually.',
      };
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.invitation,
    builder: (context, _) {
      final controller = widget.invitation;
      final current = controller.invitation;
      final changed =
          _actedOn != null &&
          (!controller.usable ||
              current?.token != _actedOn!.token ||
              current?.id != _actedOn!.id);
      return AlertDialog(
        title: Text(
          widget.recipientNumber == null
              ? 'Share invitation'
              : 'Invite ${widget.recipientName?.isNotEmpty == true ? widget.recipientName : 'selected contact'}',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.recipientNumber != null) ...[
                SelectableText(
                  widget.recipientNumber!,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                Text(
                  invitationSmsNumber(widget.recipientNumber!) == null
                      ? 'This number cannot be used for a personal SMS link. Use Share and choose the recipient there.'
                      : 'Copy the current invitation, then open your SMS app and paste it. Requires an SMS app on your device.',
                  style: const TextStyle(fontSize: 12, height: 1.7),
                ),
                const SizedBox(height: 12),
              ],
              if (controller.usable && current != null)
                SelectableText(
                  _message(current),
                  key: const Key('invitation-message'),
                  style: const TextStyle(fontSize: 13, height: 1.7),
                )
              else
                const Text('Your invitation is being renewed. Please wait.'),
              if (controller.error != null) ...[
                Text(controller.error!),
                TextButton(
                  onPressed: controller.loading ? null : controller.refresh,
                  child: const Text('Retry invitation'),
                ),
              ],
              if (!_busy && (changed || _status != null))
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    changed
                        ? 'The invitation changed. Review the current invitation and tap again.'
                        : _status!,
                    key: const Key('invitation-action-status'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (!widget.actions.canShare)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'System sharing is unavailable in this browser. You can copy the invitation.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            key: const Key('copy-live-invitation'),
            onPressed: _busy || !controller.usable
                ? null
                : () => _perform(sharing: false),
            child: const Text('Copy invitation'),
          ),
          if (widget.recipientNumber != null &&
              invitationSmsNumber(widget.recipientNumber!) != null)
            TextButton(
              key: const Key('open-invitation-sms'),
              onPressed: _busy || !_copyIsCurrent ? null : _openSms,
              child: const Text('Open SMS app'),
            ),
          if (widget.actions.canShare)
            TextButton(
              key: const Key('share-live-invitation'),
              onPressed: _busy || !controller.usable
                  ? null
                  : () => _perform(sharing: true),
              child: const Text('Share via…'),
            ),
        ],
      );
    },
  );
}
