import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const _blue = Color(0xFF14679E);
const _surface = Color(0xFFF4F4F4);

/// P15: 61683:4159/4166 and 61934:2316/2323, plus sibling 2340–2344.
/// A milestone uses completed invited registrations, not the number of contacts.
class ContinueSetupCard extends StatelessWidget {
  const ContinueSetupCard({
    super.key,
    required this.invitedRegistrations,
    required this.onInvite,
  });
  final int invitedRegistrations;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    if (invitedRegistrations >= 10) return const SizedBox.shrink();
    final second = invitedRegistrations >= 2;
    final height = second ? 400.0 : 423.0;
    final profileTop = second ? 267.0 : 292.0;
    return SizedBox(
      key: const Key('continue-setup-card'),
      width: 314,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(30),
        ),
        child: Stack(
          children: [
            const Positioned(
              left: 32,
              top: 37,
              width: 101,
              height: 22,
              child: _SourceText(
                'Continue setup',
                key: Key('continue-setup-title'),
              ),
            ),
            Positioned(
              left: 246,
              top: 37,
              width: 37,
              height: 22,
              child: _SourceText(
                second ? '2 of 3' : '1 of 3',
                key: const Key('continue-setup-stage'),
              ),
            ),
            Positioned(
              left: 32,
              top: 74,
              width: 250,
              height: 11,
              child: DecoratedBox(
                key: const Key('continue-setup-track'),
                decoration: BoxDecoration(
                  color: _blue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            Positioned(
              left: 32,
              top: 74,
              width: second ? 172 : 88.08988952636719,
              height: second ? 11 : 11.187970161437988,
              child: DecoratedBox(
                key: const Key('continue-setup-fill'),
                decoration: BoxDecoration(
                  color: _blue,
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            const Positioned(
              left: 32,
              top: 124,
              width: 16,
              height: 16,
              child: _MilestoneIcon(complete: false),
            ),
            const Positioned(
              left: 62,
              top: 121,
              width: 156,
              height: 22,
              child: _SourceText('10+ Connections'),
            ),
            // Only the explicitly rejected obsolete job-search line is removed.
            const Positioned(
              left: 62,
              top: 147,
              width: 220,
              height: 65,
              child: _SourceText(
                'Offer unlimited skills & services\nOutreach offline community ',
                size: 12,
                lineHeight: 21,
                weight: FontWeight.w300,
              ),
            ),
            Positioned(
              left: 32,
              top: 229,
              width: 16,
              height: 16,
              child: _MilestoneIcon(complete: second),
            ),
            const Positioned(
              left: 62,
              top: 226,
              width: 156,
              height: 22,
              child: _SourceText('2+ Connections'),
            ),
            if (second)
              const Positioned(
                left: 60,
                top: 240,
                width: 107,
                height: 1,
                child: ColoredBox(color: Colors.black),
              )
            else
              const Positioned(
                left: 62,
                top: 254,
                width: 213,
                height: 26,
                child: _SourceText(
                  'Message anyone, anytime',
                  size: 12,
                  lineHeight: 21,
                  weight: FontWeight.w300,
                ),
              ),
            Positioned(
              left: 32,
              top: profileTop + 3,
              width: 16,
              height: 16,
              child: const _MilestoneIcon(complete: true),
            ),
            Positioned(
              left: 62,
              top: profileTop,
              width: 106,
              height: 22,
              child: const _SourceText(
                'Complete profile ',
                weight: FontWeight.w300,
              ),
            ),
            Positioned(
              left: 60,
              top: profileTop + 14,
              width: 115,
              height: 1,
              child: const ColoredBox(color: Colors.black),
            ),
            Positioned(
              left: 87,
              top: second ? 319.38916015625 : 346.87646484375,
              width: 140,
              height: second ? 38.70182418823242 : 36.64982986450195,
              child: TextButton(
                key: const Key('continue-setup-invite'),
                onPressed: onInvite,
                style: TextButton.styleFrom(
                  backgroundColor: _blue,
                  foregroundColor: _surface,
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
                child: const Text('Invite'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceText extends StatelessWidget {
  const _SourceText(
    this.value, {
    super.key,
    this.size = 14,
    this.lineHeight = 22,
    this.weight = FontWeight.w400,
  });
  final String value;
  final double size, lineHeight;
  final FontWeight weight;
  @override
  Widget build(BuildContext context) => Text(
    value,
    style: TextStyle(
      fontFamily: 'NotoSans',
      fontSize: size,
      height: lineHeight / size,
      fontWeight: weight,
      color: Colors.black,
    ),
  );
}

class _MilestoneIcon extends StatelessWidget {
  const _MilestoneIcon({required this.complete});
  final bool complete;
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/setup-check-circle${complete ? '-fill' : ''}.svg',
    width: 16,
    height: 16,
    excludeFromSemantics: true,
  );
}

/// Open only after an action is blocked. True means open the existing invite flow.
/// No completion popup is introduced for an already-unlocked member.
Future<bool?> showContinueSetupDialog(
  BuildContext context, {
  required int invitedRegistrations,
}) async {
  if (invitedRegistrations >= 10) return false;
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 3, vertical: 24),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ContinueSetupCard(
          invitedRegistrations: invitedRegistrations,
          onInvite: () => Navigator.of(dialogContext).pop(true),
        ),
      ),
    ),
  );
}
