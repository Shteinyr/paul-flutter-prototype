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
    if (_picking || _acting) return;
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
        InvitationActionResult.completed => null,
        InvitationActionResult.cancelled =>
          'Contact selection cancelled. You can use Share or try again.',
        InvitationActionResult.denied =>
          'Contact access was blocked. You can use Share or try again.',
        InvitationActionResult.unavailable =>
          'Contact selection is unavailable. Use Share to invite someone.',
        InvitationActionResult.failed =>
          'Could not select contacts. You can use Share or try again.',
      };
    });
  }

  bool _acting = false;
  String? _actionStatus;
  bool _manualCopy = false;
  LiveInvitation? _actedOn;
  bool get _credentialsChanged =>
      _actedOn != null &&
      (!widget.invitation.usable ||
          widget.invitation.invitation?.id != _actedOn!.id ||
          widget.invitation.invitation?.token != _actedOn!.token);

  String _message(LiveInvitation invite) {
    final link = widget.appUrl.replace(fragment: 'invite=${invite.token}');
    return 'Hey, let’s connect in Paul.\n$link\nUse invite code: ${invite.code}\nValid for 15 minutes from generation.';
  }

  Future<void> _perform({bool copying = false, String? number}) async {
    if (_acting || _picking) return;
    final controller = widget.invitation;
    final current = controller.invitation;
    if (!controller.usable || current == null) {
      await controller.refresh();
      if (mounted) {
        setState(() {
          _actionStatus = controller.usable
              ? 'The invitation changed. Review the current invitation and tap again.'
              : null;
        });
      }
      return;
    }
    final safeNumber = number == null ? null : invitationSmsNumber(number);
    if (number != null && safeNumber == null) {
      setState(() {
        _actionStatus =
            'This number cannot be used for an SMS invitation. Use Share to choose a recipient.';
      });
      return;
    }
    setState(() {
      _acting = true;
      _actionStatus = null;
      _manualCopy = false;
      _actedOn = current;
    });
    InvitationActionResult result;
    try {
      // Start the actual OS/browser operation in the original button gesture.
      // No intermediate application dialog or async preflight consumes activation.
      result = await (safeNumber != null
          ? _actions.openSms(safeNumber, message: _message(current))
          : copying
          ? _actions.copy(_message(current))
          : _actions.share(_message(current)));
    } catch (_) {
      result = InvitationActionResult.failed;
    }
    if (!mounted) return;
    if (!controller.usable && !controller.loading) await controller.refresh();
    if (!mounted) return;
    final changed =
        !controller.usable ||
        controller.invitation?.id != current.id ||
        controller.invitation?.token != current.token;
    setState(() {
      _acting = false;
      _manualCopy = copying && result != InvitationActionResult.completed;
      _actionStatus = changed
          ? 'The invitation changed. Review the current invitation and tap again.'
          : switch (result) {
              InvitationActionResult.completed =>
                copying
                    ? 'Invitation copied.'
                    : safeNumber != null
                    ? 'Requested SMS app for the selected number. Confirm delivery there.'
                    : 'Share request completed. Confirm delivery in the receiving app.',
              InvitationActionResult.cancelled =>
                'Sharing cancelled. You can try again or copy the invitation.',
              InvitationActionResult.unavailable =>
                'This action is unavailable. You can copy the invitation.',
              InvitationActionResult.denied =>
                'This action was blocked. Try again or select and copy the invitation manually.',
              InvitationActionResult.failed =>
                'Could not complete this action. Try again or copy the invitation.',
            };
    });
  }

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
                Column(
                  children: [
                    TextButton(
                      key: const Key('share-live-invitation'),
                      onPressed: _acting || _picking || !_actions.canShare
                          ? null
                          : () => _perform(),
                      child: const Text(
                        'Share',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w300,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('copy-live-invitation'),
                      onPressed: _acting || _picking
                          ? null
                          : () => _perform(copying: true),
                      child: const Text('Copy invitation'),
                    ),
                  ],
                ),
              ],
            ),
            if (!_acting && (_actionStatus != null || _credentialsChanged))
              Text(
                _credentialsChanged
                    ? 'The invitation changed. Review the current invitation and tap again.'
                    : _actionStatus!,
                key: const Key('invitation-action-status'),
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
            if (!_actions.canShare)
              const Text(
                'System sharing is unavailable. You can copy the invitation.',
                style: TextStyle(fontSize: 12, height: 1.7),
              ),
            if (_manualCopy && widget.invitation.usable)
              SelectableText(
                _message(widget.invitation.invitation!),
                key: const Key('invitation-message'),
                style: const TextStyle(fontSize: 12, height: 1.7),
              ),
            if (widget.invitation.error != null) ...[
              Text(
                widget.invitation.error!,
                style: const TextStyle(fontSize: 12),
              ),
              TextButton(
                onPressed: widget.invitation.loading
                    ? null
                    : widget.invitation.refresh,
                child: const Text('Retry invitation'),
              ),
            ],
            const SizedBox(height: 20),
            const Divider(color: Color(0x2214679E), height: 1),
            const SizedBox(height: 20),
            if (_actions.canPickContacts)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('pick-invitation-contacts'),
                  onPressed: _picking || _acting ? null : _pickContacts,
                  child: Text(
                    _picking ? 'Selecting contacts…' : 'Invite a contact',
                  ),
                ),
              )
            else
              const Text(
                'Contact selection is unavailable. Use Share to invite someone.',
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
                      onPressed: _acting || _picking
                          ? null
                          : () => _perform(number: phone),
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
