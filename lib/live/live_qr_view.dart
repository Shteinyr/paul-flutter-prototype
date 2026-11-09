import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app.dart';
import '../profile/profile_controller.dart';
import '../profile/public_profile_view.dart';
import 'invitation_controller.dart';

const _blue = Color(0xFF14679E);

class LiveQrView extends StatefulWidget {
  const LiveQrView({
    super.key,
    required this.profile,
    required this.issuer,
    required this.appUrl,
  });
  final ProfileController profile;
  final InvitationIssuer issuer;
  final Uri appUrl;
  @override
  State<LiveQrView> createState() => _LiveQrViewState();
}

class _LiveQrViewState extends State<LiveQrView> with WidgetsBindingObserver {
  late final InvitationController _invitation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _invitation = InvitationController(widget.issuer)..start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _invitation.start();
    } else {
      _invitation.pause();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.profile, _invitation]),
    builder: (context, _) {
      final profile = widget.profile.profile;
      final invite = _invitation.invitation;
      final remaining = _invitation.remaining.inSeconds;
      return ProfilePage(
        title: '',
        action: IconButton(
          key: const Key('open-connect'),
          tooltip: 'Connect',
          color: _blue,
          icon: const Icon(Icons.link, size: 22),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _LiveConnectView(
                invitation: _invitation,
                appUrl: widget.appUrl,
              ),
            ),
          ),
        ),
        child: SingleChildScrollView(
          key: const Key('qr-scroll'),
          padding: const EdgeInsets.fromLTRB(37.5, 68, 37.5, 44),
          child: Column(
            children: [
              ProfileAvatar(photo: profile.photo, size: 144),
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
              SizedBox(
                width: 176,
                height: 176,
                child: _invitation.usable && invite != null
                    ? QrImageView(
                        key: const Key('live-qr-image'),
                        data: widget.appUrl
                            .replace(fragment: 'invite=${invite.token}')
                            .toString(),
                        size: 176,
                        padding: EdgeInsets.zero,
                        semanticsLabel:
                            'Invitation QR code, valid for 15 minutes',
                      )
                    : const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
              ),
              const SizedBox(height: 24),
              if (_invitation.usable && invite != null) ...[
                SelectableText(
                  invite.code,
                  key: const Key('live-invite-code'),
                  style: const TextStyle(
                    fontSize: 12,
                    height: 20 / 12,
                    fontWeight: FontWeight.w300,
                    letterSpacing: .5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'New QR in ${remaining ~/ 60}:${(remaining % 60).toString().padLeft(2, '0')}',
                  key: const Key('invite-countdown'),
                  style: const TextStyle(fontSize: 11, color: Colors.black54),
                ),
                TextButton(
                  onPressed: _invitation.loading ? null : _invitation.revoke,
                  child: const Text(
                    'Revoke and generate new',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ] else if (_invitation.error == null) ...[
                const Text(
                  'Generating a new invitation…',
                  style: TextStyle(fontSize: 11, color: Colors.black54),
                ),
              ],
              if (_invitation.error != null) ...[
                Text(
                  _invitation.error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
                TextButton(
                  onPressed: _invitation.loading ? null : _invitation.refresh,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _invitation.dispose();
    super.dispose();
  }
}

class _LiveConnectView extends StatelessWidget {
  const _LiveConnectView({required this.invitation, required this.appUrl});
  final InvitationController invitation;
  final Uri appUrl;

  Future<void> _share(BuildContext context) async {
    var copying = false;
    String? copyError;
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setDialogState) => ListenableBuilder(
          listenable: invitation,
          builder: (context, _) => AlertDialog(
            title: const Text('Share invitation'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (invitation.usable)
                  SelectableText(
                    _message(),
                    style: const TextStyle(fontSize: 13, height: 1.7),
                  )
                else
                  const Text('Your invitation is being renewed. Please wait.'),
                if (copyError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      copyError!,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              TextButton(
                key: const Key('copy-live-invitation'),
                onPressed: copying || !invitation.usable
                    ? null
                    : () async {
                        setDialogState(() {
                          copying = true;
                          copyError = null;
                        });
                        try {
                          await Clipboard.setData(
                            ClipboardData(text: _message()),
                          );
                          if (!context.mounted ||
                              ModalRoute.of(context)?.isCurrent != true) {
                            return;
                          }
                          Navigator.of(context).pop();
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
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _message() {
    final current = invitation.invitation!;
    final link = appUrl.replace(fragment: 'invite=${current.token}');
    return 'Hey, let’s connect in Paul.\n$link\nUse invite code: ${current.code}\nValid for 15 minutes from generation.';
  }

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Connect',
    child: ListenableBuilder(
      listenable: invitation,
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
                        invitation.usable
                            ? 'Use invite code: ${invitation.invitation!.code}'
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
                  onPressed: invitation.usable
                      ? () => unawaited(_share(context))
                      : null,
                  child: const Text(
                    'Share',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w300),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Divider(color: Color(0x2214679E), height: 1),
          ],
        ),
      ),
    ),
  );
}
