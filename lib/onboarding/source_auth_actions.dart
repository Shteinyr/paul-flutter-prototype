import 'package:flutter/material.dart';

/// Exact P09 action 61852:2893–2897. The caller owns provider availability/OAuth.
/// There is no source-backed custom Google/Apple selector dialog in this export.
class SourceGoogleContinueButton extends StatelessWidget {
  const SourceGoogleContinueButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 217,
    height: 39,
    child: TextButton(
      key: const Key('source-continue-google'),
      onPressed: onPressed,
      style: TextButton.styleFrom(
        backgroundColor: const Color(0xFF14679E),
        disabledBackgroundColor: const Color(0xFF14679E),
        foregroundColor: const Color(0xFFF4F4F4),
        disabledForegroundColor: const Color(0xFFF4F4F4),
        padding: EdgeInsets.zero,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        textStyle: const TextStyle(
          fontFamily: 'NotoSans',
          fontSize: 15,
          height: 20 / 15,
          fontWeight: FontWeight.w500,
        ),
      ),
      child: const Text('Continue with Google'),
    ),
  );
}
