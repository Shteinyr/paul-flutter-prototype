import 'package:flutter/material.dart';

import 'onboarding/onboarding_flow.dart';

/// Local UI review entrypoint. Live registration supplies its real onComplete.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      title: 'Paul — Registration review',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'NotoSans',
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF14679E)),
      ),
      home: OnboardingFlow(
        onComplete: (_) async {
          throw const OnboardingSubmissionException(
            'Your draft is saved. Continue sign-in in the connected registration version.',
          );
        },
      ),
    ),
  );
}
