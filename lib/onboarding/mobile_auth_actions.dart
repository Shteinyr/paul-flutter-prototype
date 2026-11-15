import 'package:flutter/material.dart';
import 'source_auth_actions.dart';

/// Google is P09 61852:2893–2897. Apple on BOTH platforms is Alexander's
/// explicit 15 November decision; reuse the same action style and add no copy.
class MobileAuthActions extends StatelessWidget {
  const MobileAuthActions({
    super.key,
    required this.onGoogle,
    required this.onApple,
  });
  final VoidCallback? onGoogle, onApple;
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SourceGoogleContinueButton(onPressed: onGoogle),
      const SizedBox(height: 12),
      SizedBox(
        width: 217,
        height: 39,
        child: TextButton(
          key: const Key('continue-apple'),
          onPressed: onApple,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF14679E),
            padding: EdgeInsets.zero,
            textStyle: const TextStyle(
              fontFamily: 'NotoSans',
              fontSize: 15,
              height: 20 / 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          child: const Text('Continue with Apple'),
        ),
      ),
    ],
  );
}
