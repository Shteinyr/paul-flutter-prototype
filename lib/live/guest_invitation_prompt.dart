import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const _blue = Color(0xFF14679E);
const _surface = Color(0xFFF4F4F4);

/// P16 61674:3956–3960: a lock and the exact invitation action, not a chat inbox.
class GuestChatPrompt extends StatelessWidget {
  const GuestChatPrompt({super.key, required this.onSignUp});
  final VoidCallback onSignUp;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 204,
    height: 57,
    child: Stack(
      children: [
        Positioned(
          left: 92,
          top: 0,
          width: 20,
          height: 20,
          child: SvgPicture.asset(
            'assets/icons/guest-chat-lock.svg',
            excludeFromSemantics: true,
          ),
        ),
        Positioned(
          left: 0,
          top: 34,
          width: 204,
          height: 23,
          child: TextButton(
            key: const Key('guest-sign-up-chat'),
            onPressed: onSignUp,
            style: TextButton.styleFrom(
              foregroundColor: _blue,
              padding: EdgeInsets.zero,
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontFamily: 'NotoSans',
                fontSize: 12,
                height: 20 / 12,
                fontWeight: FontWeight.w300,
              ),
            ),
            child: const Text('Sign up to chat'),
          ),
        ),
      ],
    ),
  );
}

/// P16 source 61859:3285–3295. Caller supplies an existing live manual invitation;
/// this widget never issues a code, authenticates a user or chooses a store URL.
class GuestInvitationPrompt extends StatelessWidget {
  const GuestInvitationPrompt({
    super.key,
    required this.invitationCode,
    required this.onGetApp,
    this.onCopyCode,
  });
  final String invitationCode;
  final VoidCallback? onGetApp, onCopyCode;
  static bool validCode(String value) => RegExp(r'^\d{8}$').hasMatch(value);
  @override
  Widget build(BuildContext context) {
    if (!validCode(invitationCode)) return const SizedBox.shrink();
    return SizedBox(
      key: const Key('guest-invitation-prompt'),
      width: 314,
      height: 216,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Stack(
          children: [
            const Positioned(
              left: 61,
              top: 40,
              width: 193,
              height: 20,
              child: Text(
                'You’re Invited!',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'NotoSans',
                  fontSize: 16,
                  height: 20 / 16,
                  fontWeight: FontWeight.w500,
                  color: Colors.black,
                ),
              ),
            ),
            const Positioned(
              left: 13,
              top: 60,
              width: 288,
              height: 27,
              child: Text(
                'Copy, paste code in App to connect',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: 'NotoSans',
                  fontSize: 12,
                  height: 20 / 12,
                  fontWeight: FontWeight.w300,
                  color: Colors.black,
                ),
              ),
            ),
            Positioned(
              left: 104,
              top: 85,
              width: 106,
              height: 42.167598724365234,
              child: TextButton(
                key: const Key('guest-invitation-code'),
                onPressed: onCopyCode,
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: Colors.black,
                  disabledForegroundColor: Colors.black,
                  textStyle: const TextStyle(
                    fontFamily: 'NotoSans',
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),
                child: Text(invitationCode, textAlign: TextAlign.center),
              ),
            ),
            Positioned(
              left: 87,
              top: 139,
              width: 140,
              height: 41,
              child: TextButton(
                key: const Key('guest-get-app'),
                onPressed: onGetApp,
                style: TextButton.styleFrom(
                  backgroundColor: _blue,
                  disabledBackgroundColor: _blue,
                  foregroundColor: _surface,
                  disabledForegroundColor: _surface,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30),
                  ),
                  textStyle: const TextStyle(
                    fontFamily: 'NotoSans',
                    fontSize: 15,
                    height: 20 / 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                child: const Text('Get app'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<bool?> showGuestInvitationDialog(
  BuildContext context, {
  required String invitationCode,
  VoidCallback? onCopyCode,
}) async {
  if (!GuestInvitationPrompt.validCode(invitationCode)) return false;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 3, vertical: 24),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: GuestInvitationPrompt(
          invitationCode: invitationCode,
          onCopyCode: onCopyCode,
          onGetApp: () => Navigator.of(dialogContext).pop(true),
        ),
      ),
    ),
  );
}
