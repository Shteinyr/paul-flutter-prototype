import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'profile/public_profile_view.dart';
import 'profile/user_profile.dart';

const demoInviteCode = '84654619';
const _blue = Color(0xFF14679E);
const demoAddressBook = [
  'Alex Parker',
  'Nina Patel',
  'James Miller',
  'Lena Fischer',
  'Sam Taylor',
];
const _invitation =
    'Demo invitation — let’s connect in Paul.\nUse invite code: $demoInviteCode';

/// Session-only demonstration state. No device contacts or messages are used.
class DemoConnectState extends ChangeNotifier {
  bool contactsAllowed = false;
  final Set<String> _prepared = {};
  bool isPrepared(String name) => _prepared.contains(name);
  void allowContacts() {
    contactsAllowed = true;
    notifyListeners();
  }

  void prepare(String name) {
    _prepared.add(name);
    notifyListeners();
  }

  void reset() {
    contactsAllowed = false;
    _prepared.clear();
    notifyListeners();
  }
}

class DemoQrView extends StatelessWidget {
  const DemoQrView({
    super.key,
    required this.profile,
    required this.avatar,
    required this.state,
  });
  final UserProfile profile;
  final Widget avatar;
  final DemoConnectState state;

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: '',
    action: IconButton(
      key: const Key('open-connect'),
      tooltip: 'Connect',
      color: _blue,
      icon: const Icon(Icons.link, size: 22),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => DemoConnectView(state: state)),
      ),
    ),
    child: SingleChildScrollView(
      key: const Key('qr-scroll'),
      padding: const EdgeInsets.fromLTRB(37.5, 68, 37.5, 44),
      child: Column(
        children: [
          avatar,
          const SizedBox(height: 32),
          Text(
            profile.name,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 16,
              height: 20 / 16,
              fontWeight: FontWeight.w500,
              letterSpacing: .5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            profile.occupation,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 20 / 12,
              fontWeight: FontWeight.w300,
              letterSpacing: .5,
            ),
          ),
          const SizedBox(height: 24),
          Semantics(
            label: 'Demonstration QR code, invite code $demoInviteCode',
            image: true,
            child: SvgPicture.asset(
              'assets/icons/demo-invite-qr.svg',
              key: const Key('demo-qr-image'),
              width: 176,
              height: 176,
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(height: 24),
          const SelectableText(
            demoInviteCode,
            style: TextStyle(
              fontSize: 12,
              height: 20 / 12,
              fontWeight: FontWeight.w300,
              letterSpacing: .5,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Demo invite',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
        ],
      ),
    ),
  );
}

class DemoConnectView extends StatefulWidget {
  const DemoConnectView({super.key, required this.state});
  final DemoConnectState state;
  @override
  State<DemoConnectView> createState() => _DemoConnectViewState();
}

class _DemoConnectViewState extends State<DemoConnectView> {
  Future<void> _preview({String? recipient}) async {
    var copying = false;
    String? copyError;
    final prepared = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            recipient == null ? 'Share invitation' : 'Invite $recipient',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SelectableText(
                _invitation,
                style: TextStyle(fontSize: 13, height: 1.7),
              ),
              const SizedBox(height: 20),
              const Text(
                'Demo only. No invitation will be sent.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              if (copyError != null) ...[
                const SizedBox(height: 12),
                Text(
                  copyError!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Close'),
            ),
            if (recipient == null)
              TextButton(
                key: const Key('copy-demo-invitation'),
                onPressed: copying
                    ? null
                    : () async {
                        if (copying) return;
                        setDialogState(() {
                          copying = true;
                          copyError = null;
                        });
                        try {
                          await Clipboard.setData(
                            const ClipboardData(text: _invitation),
                          );
                          if (!context.mounted ||
                              ModalRoute.of(context)?.isCurrent != true) {
                            return;
                          }
                          Navigator.of(context).pop(true);
                        } catch (_) {
                          if (!context.mounted ||
                              ModalRoute.of(context)?.isCurrent != true) {
                            return;
                          }
                          setDialogState(() {
                            copying = false;
                            copyError =
                                'Could not copy invitation. Please try again.';
                          });
                        }
                      },
                child: const Text('Copy invitation'),
              )
            else
              TextButton(
                key: const Key('prepare-demo-invitation'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Prepare invite'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || prepared != true) return;
    if (recipient != null) widget.state.prepare(recipient);
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          recipient == null
              ? 'Demo invitation copied'
              : 'Demo invitation prepared for $recipient',
        ),
      ),
    );
  }

  Future<void> _invite(String name) async {
    if (!widget.state.contactsAllowed) {
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Access to Contacts'),
          content: const Text(
            'This is a demo permission request. Allow access to the sample contact list? Your device contacts will not be accessed.',
          ),
          actions: [
            TextButton(
              key: const Key('deny-demo-contacts'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Don’t Allow'),
            ),
            TextButton(
              key: const Key('allow-demo-contacts'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (!mounted || allowed != true) return;
      widget.state.allowContacts();
    }
    await _preview(recipient: name);
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Connect',
    child: SingleChildScrollView(
      key: const Key('connect-scroll'),
      padding: const EdgeInsets.fromLTRB(37.5, 36, 37.5, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Hey, let’s connect in Paul.',
                      style: TextStyle(
                        fontSize: 11,
                        height: 2.1,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    Text(
                      'Get the app from App Store or Google Play.',
                      style: TextStyle(
                        fontSize: 11,
                        height: 2.1,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: 'Use invite code:  '),
                          TextSpan(
                            text: demoInviteCode,
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        height: 2.1,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                key: const Key('share-demo-invitation'),
                onPressed: () => _preview(),
                style: TextButton.styleFrom(
                  foregroundColor: _blue,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 48),
                ),
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
          const Text(
            'Demo contacts',
            style: TextStyle(fontSize: 11, color: Colors.black54),
          ),
          const SizedBox(height: 24),
          ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) => Column(
              children: [
                for (var index = 0; index < demoAddressBook.length; index++)
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            demoAddressBook[index],
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ),
                        TextButton(
                          key: Key('invite-demo-$index'),
                          onPressed:
                              widget.state.isPrepared(demoAddressBook[index])
                              ? null
                              : () => _invite(demoAddressBook[index]),
                          style: TextButton.styleFrom(
                            foregroundColor: _blue,
                            textStyle: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                          child: Text(
                            widget.state.isPrepared(demoAddressBook[index])
                                ? 'Prepared'
                                : 'Invite',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
