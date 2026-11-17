import 'dart:async';
import 'package:flutter/material.dart';

import '../profile/public_profile_view.dart';
import '../platform/invitations/contact_source.dart';
import 'invitation_actions.dart';
import 'invitation_controller.dart';

class LiveConnectView extends StatefulWidget {
  const LiveConnectView({
    super.key,
    required this.invitation,
    required this.appUrl,
    this.actions,
    this.contacts,
  });
  final InvitationController invitation;
  final Uri appUrl;
  final InvitationActions? actions;
  final InvitationContactSource? contacts;
  @override
  State<LiveConnectView> createState() => _LiveConnectViewState();
}

class _LiveConnectViewState extends State<LiveConnectView>
    with WidgetsBindingObserver {
  late final InvitationActions _actions =
      widget.actions ?? createInvitationActions();
  late InvitationContactSource _source;
  InvitationContacts _contacts = const InvitationContacts(
    InvitationContactAccess.notDetermined,
  );
  final _scroll = ScrollController();
  StreamSubscription<void>? _changes;
  Timer? _changeTimer;
  Future<void>? _loadingTask;
  bool _loadAgain = false, _requestPermission = false, _loadingContacts = false;
  bool _resumed = true, _contactsDirty = false, _openingSettings = false;
  bool _choosingNumber = false;
  int _contactGeneration = 0;
  DialogRoute<String>? _numberRoute;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _useSource();
    // Entering Connect is the deliberate request. Resume never prompts again.
    unawaited(_loadContacts(requestPermission: true));
  }

  void _useSource() {
    _source = widget.contacts ?? createInvitationContactSource();
    _changes = _source.changes.listen(
      (_) => _scheduleContactRefresh(),
      onError: (Object _) => _scheduleContactRefresh(),
    );
  }

  @override
  void didUpdateWidget(LiveConnectView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contacts != widget.contacts) {
      unawaited(_changes?.cancel());
      _contacts = const InvitationContacts(
        InvitationContactAccess.notDetermined,
      );
      _useSource();
      unawaited(_loadContacts(requestPermission: true));
    }
  }

  void _scheduleContactRefresh() {
    if (!mounted) return;
    _contactsDirty = true;
    _contactGeneration++;
    _dismissNumberChoice();
    _changeTimer?.cancel();
    if (_resumed) {
      _changeTimer = Timer(const Duration(milliseconds: 200), () {
        unawaited(_loadContacts());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _changeTimer?.cancel();
    if (_resumed) {
      unawaited(_loadContacts());
    } else {
      _dismissNumberChoice();
    }
  }

  Future<void> _loadContacts({bool requestPermission = false}) {
    if (!mounted) return Future.value();
    _contactGeneration++;
    _dismissNumberChoice();
    _loadAgain = true;
    _requestPermission |= requestPermission;
    return _loadingTask ??= _drainContactLoads().whenComplete(
      () => _loadingTask = null,
    );
  }

  Future<void> _drainContactLoads() async {
    setState(() => _loadingContacts = true);
    while (_loadAgain && mounted) {
      _loadAgain = false;
      final generation = _contactGeneration;
      final request = _requestPermission;
      _requestPermission = false;
      InvitationContacts result;
      try {
        result = await _source.load(requestPermission: request);
      } catch (_) {
        result = const InvitationContacts(InvitationContactAccess.failed);
      }
      if (!mounted) return;
      if (generation != _contactGeneration) continue;
      setState(() {
        // Denied/restricted responses must not retain a previously readable book.
        _contacts = result.readable
            ? result
            : InvitationContacts(result.access);
        _contactsDirty = false;
      });
    }
    if (mounted) setState(() => _loadingContacts = false);
  }

  void _dismissNumberChoice() {
    final route = _numberRoute;
    _numberRoute = null;
    if (route != null && route.isActive) route.navigator?.removeRoute(route);
  }

  Future<void> _invite(InvitationContact contact) async {
    if (_acting ||
        _choosingNumber ||
        _loadingContacts ||
        _contactsDirty ||
        !_contacts.readable) {
      return;
    }
    final numbers = invitationContactNumbers(contact);
    if (numbers.isEmpty) return;
    final generation = _contactGeneration;
    String? number = numbers.first;
    if (numbers.length > 1) {
      _choosingNumber = true;
      final route = DialogRoute<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(contact.name.isEmpty ? 'Contact' : contact.name),
          children: [
            for (final value in numbers)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, value),
                child: Text(value),
              ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
      _numberRoute = route;
      try {
        number = await Navigator.of(context).push(route);
      } finally {
        if (identical(_numberRoute, route)) _numberRoute = null;
        _choosingNumber = false;
      }
    }
    if (!mounted ||
        number == null ||
        generation != _contactGeneration ||
        !_contacts.readable) {
      return;
    }
    await _perform(number: number);
  }

  Future<void> _settings() async {
    if (_openingSettings) return;
    setState(() => _openingSettings = true);
    try {
      await _source.openSettings();
    } catch (_) {
      if (mounted) {
        setState(
          () => _contacts = const InvitationContacts(
            InvitationContactAccess.failed,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingSettings = false);
    }
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
    if (_acting || _choosingNumber) return;
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

  Widget _contactState() {
    final access = _contacts.access;
    if (_loadingContacts && !_contacts.readable) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final message = switch (access) {
      InvitationContactAccess.notDetermined =>
        'Allow Contacts to see people you can invite.',
      InvitationContactAccess.denied ||
      InvitationContactAccess.permanentlyDenied =>
        'Contact access was denied. You can still share or copy your invitation.',
      InvitationContactAccess.restricted =>
        'Contact access is restricted. You can still share or copy your invitation.',
      InvitationContactAccess.limited => 'Only contacts you allow are shown.',
      InvitationContactAccess.unavailable =>
        'Contacts are unavailable here. You can share or copy your invitation.',
      InvitationContactAccess.failed =>
        'Could not load contacts. Please retry.',
      InvitationContactAccess.granted =>
        _contacts.contacts.isEmpty ? 'No contacts available.' : null,
    };
    final settings =
        access == InvitationContactAccess.permanentlyDenied ||
        access == InvitationContactAccess.restricted ||
        access == InvitationContactAccess.limited;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (message != null)
          Text(
            message,
            key: const Key('invitation-contact-status'),
            style: const TextStyle(fontSize: 12, height: 1.7),
          ),
        if (access == InvitationContactAccess.limited &&
            _contacts.contacts.isEmpty)
          const Text('No contacts available.', style: TextStyle(fontSize: 12)),
        if (settings)
          TextButton(
            key: const Key('invitation-contact-settings'),
            onPressed: _openingSettings ? null : _settings,
            child: Text(
              access == InvitationContactAccess.limited
                  ? 'Manage Contacts'
                  : 'Open Settings',
            ),
          ),
        if (access == InvitationContactAccess.notDetermined ||
            access == InvitationContactAccess.denied)
          TextButton(
            key: const Key('request-invitation-contacts'),
            onPressed: _loadingContacts
                ? null
                : () => _loadContacts(requestPermission: true),
            child: const Text('Allow Contacts'),
          ),
        if (access == InvitationContactAccess.failed)
          TextButton(
            key: const Key('retry-invitation-contacts'),
            onPressed: _loadingContacts ? null : () => _loadContacts(),
            child: const Text('Retry'),
          ),
      ],
    );
  }

  Widget _contactRow(int index) {
    final contact = _contacts.contacts[index];
    final numbers = invitationContactNumbers(contact);
    return Padding(
      key: ValueKey(
        'invitation-contact-${contact.id.isEmpty ? index : contact.id}',
      ),
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.name.isEmpty ? 'Contact' : contact.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (numbers.isEmpty)
                  const Text('No phone number', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          TextButton(
            onPressed:
                numbers.isEmpty || _acting || _loadingContacts || _contactsDirty
                ? null
                : () => _invite(contact),
            child: const Text('Invite'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Connect',
    child: ListenableBuilder(
      listenable: widget.invitation,
      builder: (context, _) => CustomScrollView(
        key: const Key('connect-contacts-list'),
        controller: _scroll,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(37.5, 36, 37.5, 0),
            sliver: SliverToBoxAdapter(
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
                            onPressed:
                                _acting || _choosingNumber || !_actions.canShare
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
                            onPressed: _acting || _choosingNumber
                                ? null
                                : () => _perform(copying: true),
                            child: const Text('Copy invitation'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (!_acting &&
                      (_actionStatus != null || _credentialsChanged))
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

                  _contactState(),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(37.5, 0, 37.5, 48),
            sliver: SliverList.builder(
              itemCount: _contacts.readable ? _contacts.contacts.length : 0,
              itemBuilder: (_, index) => _contactRow(index),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changeTimer?.cancel();
    unawaited(_changes?.cancel());
    _scroll.dispose();
    super.dispose();
  }
}
