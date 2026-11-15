import 'dart:async';
import 'dart:io';
import 'incoming_links.dart';

Future<void> Function() observePlatformInvitations(
  Uri appUrl,
  void Function(String) onInvitation,
) {
  if (!Platform.isIOS && !Platform.isAndroid) return () async {};
  final listener = IncomingLinkListener(
    source: NativeIncomingLinkSource(),
    parser: IncomingLinkParser(
      invitationBase: appUrl,
      oauthCallback: Uri.parse('app.paul://login-callback'),
    ),
  );
  unawaited(
    listener.start((link) {
      if (link is InvitationLink) onInvitation(link.credential);
    }),
  );
  return listener.dispose;
}
