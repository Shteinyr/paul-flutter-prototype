import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app.dart';
import '../profile/profile_controller.dart';
import '../profile/public_profile_view.dart';
import 'invitation_controller.dart';
import 'live_connect_view.dart';

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
      return ProfilePage(
        title: '',
        action: IconButton(
          key: const Key('open-connect'),
          tooltip: 'Connect',
          color: _blue,
          icon: const Icon(Icons.link, size: 22),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => LiveConnectView(
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
