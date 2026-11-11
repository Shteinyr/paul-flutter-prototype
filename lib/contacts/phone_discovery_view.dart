import 'dart:async';

import 'package:flutter/material.dart';

import '../live/invitation_actions.dart';
import '../profile/public_profile_view.dart';
import 'phone_discovery_api.dart';
import 'phone_discovery_controller.dart';

class PhoneDiscoveryView extends StatefulWidget {
  const PhoneDiscoveryView({
    super.key,
    required this.repository,
    required this.onProfile,
    required this.onInvite,
    this.actions,
  });
  final PhoneDiscoveryRepository repository;
  final Future<void> Function(String id) onProfile;
  final VoidCallback onInvite;
  final InvitationActions? actions;
  @override
  State<PhoneDiscoveryView> createState() => _PhoneDiscoveryViewState();
}

class _PhoneDiscoveryViewState extends State<PhoneDiscoveryView>
    with WidgetsBindingObserver {
  late final PhoneDiscoveryController _controller;
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _number = TextEditingController();
  final _country = TextEditingController();
  bool _changingPhone = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = PhoneDiscoveryController(
      widget.repository,
      widget.actions ?? createInvitationActions(),
    );
    unawaited(_controller.refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_controller.refresh());
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Find people you know',
    child: ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final controller = _controller;
        final status = controller.status;
        final ready = controller.current && !controller.busy;
        return ListView(
          padding: const EdgeInsets.fromLTRB(32, 20, 32, 40),
          children: [
            if (status == null && controller.busy)
              const Center(child: CircularProgressIndicator()),
            if (controller.error != null)
              Text(
                controller.error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            if (controller.notice != null)
              Text(controller.notice!, style: const TextStyle(fontSize: 12)),
            TextButton(
              onPressed: ready ? controller.refresh : null,
              child: const Text('Refresh phone settings'),
            ),
            if (status != null) ...[
              if (status.verified)
                Text(
                  'Verified phone ending ${status.last4 ?? ''}',
                  style: const TextStyle(fontSize: 14),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Allow people who have my number to find me',
                  style: TextStyle(fontSize: 13),
                ),
                value: status.discoverable,
                onChanged: ready && status.verified
                    ? controller.setConsent
                    : null,
              ),
              if (status.verified && !_changingPhone)
                TextButton(
                  onPressed: ready
                      ? () => setState(() => _changingPhone = true)
                      : null,
                  child: const Text('Change phone number'),
                ),
              if (!status.verified || _changingPhone) ...[
                if (controller.smsAvailable == false)
                  const Text(
                    'SMS verification is being configured. You can use the app and invite friends now.',
                    style: TextStyle(fontSize: 12),
                  ),
                TextField(
                  key: const Key('discovery-phone'),
                  controller: _phone,
                  enabled:
                      ready &&
                      controller.smsAvailable == true &&
                      controller.pendingPhone == null,
                  keyboardType: TextInputType.phone,
                  maxLength: 16,
                  decoration: const InputDecoration(
                    labelText: 'Your phone number',
                    hintText: '+country code and number',
                  ),
                ),
                if (controller.pendingPhone == null)
                  FilledButton(
                    onPressed: ready && controller.smsAvailable == true
                        ? () => controller.requestCode(_phone.text)
                        : null,
                    child: const Text('Send verification code'),
                  )
                else ...[
                  TextField(
                    key: const Key('discovery-otp'),
                    controller: _code,
                    enabled: ready,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    maxLength: 10,
                    decoration: const InputDecoration(labelText: 'SMS code'),
                  ),
                  FilledButton(
                    onPressed: ready
                        ? () async {
                            await controller.verify(_code.text);
                            if (mounted && controller.pendingPhone == null) {
                              _code.clear();
                              _phone.clear();
                              setState(() => _changingPhone = false);
                            }
                          }
                        : null,
                    child: const Text('Verify phone'),
                  ),
                  TextButton(
                    onPressed: ready
                        ? () => controller.requestCode(controller.pendingPhone!)
                        : null,
                    child: const Text('Resend code'),
                  ),
                ],
              ],
              if (status.verified) ...[
                const SizedBox(height: 24),
                const Text(
                  'We check the numbers you select when you tap Find contacts.',
                  style: TextStyle(fontSize: 12),
                ),
                if (controller.actions.canPickContacts)
                  TextButton.icon(
                    onPressed: ready ? controller.pickContacts : null,
                    icon: const Icon(Icons.contacts_outlined, size: 18),
                    label: const Text('Choose contacts'),
                  ),
                TextField(
                  key: const Key('discovery-manual-number'),
                  controller: _number,
                  enabled: ready,
                  maxLength: 128,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Contact phone number',
                  ),
                ),
                TextButton(
                  onPressed: ready
                      ? () {
                          controller.addNumber(_number.text);
                          _number.clear();
                        }
                      : null,
                  child: const Text('Add number'),
                ),
                TextField(
                  key: const Key('discovery-country'),
                  controller: _country,
                  enabled: ready,
                  maxLength: 2,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Country for local numbers (optional)',
                    hintText: 'RU, US…',
                  ),
                ),
                for (final contact in controller.contacts)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      contact.name.isEmpty ? contact.phone : contact.name,
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: contact.name.isEmpty ? null : Text(contact.phone),
                    value: contact.selected,
                    onChanged: ready
                        ? (selected) =>
                              controller.select(contact, selected == true)
                        : null,
                  ),
                if (controller.contacts.isNotEmpty) ...[
                  FilledButton(
                    key: const Key('discovery-find'),
                    onPressed: ready
                        ? () => controller.find(_country.text)
                        : null,
                    child: const Text('Find contacts'),
                  ),
                  TextButton(
                    onPressed: ready ? controller.clearContacts : null,
                    child: const Text('Clear selected contacts'),
                  ),
                ],
                if (controller.lookup case final lookup?) ...[
                  const SizedBox(height: 20),
                  for (
                    var index = 0;
                    index < controller.results.length;
                    index++
                  )
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        controller.results[index].name.isEmpty
                            ? controller.results[index].phone
                            : controller.results[index].name,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        lookup.invalid.contains(index)
                            ? 'Check the number and country'
                            : lookup.matches.containsKey(index)
                            ? 'Found on Paul'
                            : 'No discoverable profile found',
                      ),
                      trailing: lookup.invalid.contains(index)
                          ? null
                          : TextButton(
                              onPressed: !ready
                                  ? null
                                  : lookup.matches.containsKey(index)
                                  ? () =>
                                        widget.onProfile(lookup.matches[index]!)
                                  : widget.onInvite,
                              child: Text(
                                lookup.matches.containsKey(index)
                                    ? 'View profile'
                                    : 'Invite',
                              ),
                            ),
                    ),
                ],
              ],
            ],
            const SizedBox(height: 20),
            TextButton(
              onPressed: widget.onInvite,
              child: const Text('Invite friends'),
            ),
          ],
        );
      },
    ),
  );
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _phone.dispose();
    _code.dispose();
    _number.dispose();
    _country.dispose();
    super.dispose();
  }
}
