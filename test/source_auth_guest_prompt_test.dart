import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/guest_invitation_prompt.dart';
import 'package:paul_demo/live/invitation_entry_view.dart';
import 'package:paul_demo/onboarding/source_auth_actions.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  testWidgets(
    'P09 exports only the source-backed Google action without inventing a selector',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SourceGoogleContinueButton(onPressed: () => calls++),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('source-continue-google'))),
        const Size(217, 39),
      );
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Continue with Google'));
      expect(calls, 1);
      expect(find.text('Continue with Apple'), findsNothing);
    },
  );
  testWidgets(
    'P16 chat is the source lock/Sign up action and never exposes an inbox',
    (tester) async {
      var signs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(child: GuestChatPrompt(onSignUp: () => signs++)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sign up to chat'), findsOneWidget);
      expect(find.text('Sign in to view your messages.'), findsNothing);
      await tester.tap(find.text('Sign up to chat'));
      expect(signs, 1);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'P16 invitation uses the original copy, dimensions and supplied real code',
    (tester) async {
      var copies = 0, gets = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GuestInvitationPrompt(
                invitationCode: '12345678',
                onCopyCode: () => copies++,
                onGetApp: () => gets++,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('guest-invitation-prompt'))),
        const Size(314, 216),
      );
      expect(find.text('You’re Invited!'), findsOneWidget);
      expect(find.text('Copy, paste code in App to connect'), findsOneWidget);
      expect(find.text('12345678'), findsOneWidget);
      expect(find.text('Get app'), findsOneWidget);
      final origin = tester.getTopLeft(
        find.byKey(const Key('guest-invitation-prompt')),
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('guest-get-app'))) - origin,
        const Offset(87, 139),
      );
      await tester.tap(find.text('12345678'));
      await tester.tap(find.text('Get app'));
      expect(copies, 1);
      expect(gets, 1);
      expect(find.text('454687'), findsNothing);
    },
  );
  testWidgets(
    'opaque tokens and fabricated placeholder codes cannot become a visible invite',
    (tester) async {
      for (final code in ['opaque-token', '454687', '']) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: GuestInvitationPrompt(
                invitationCode: code,
                onGetApp: () {},
              ),
            ),
          ),
        );
        expect(find.text('You’re Invited!'), findsNothing);
      }
    },
  );
  testWidgets(
    'incoming QR tokens do not leak into the manual invitation field',
    (tester) async {
      const token =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(
            initialCode: token,
            pendingCredential: token,
            onJoin: (_) {},
            onSignIn: (_) {},
          ),
        ),
      );
      expect(find.text(token), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('invite-code-input')))
            .controller!
            .text,
        isEmpty,
      );
    },
  );
  testWidgets(
    'Get app dialog only returns an intent and creates no navigation on its own',
    (tester) async {
      var requested = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  requested =
                      await showGuestInvitationDialog(
                        context,
                        invitationCode: '12345678',
                      ) ==
                      true;
                },
                child: const Text('Blocked action'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Blocked action'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get app'));
      await tester.pumpAndSettle();
      expect(requested, true);
      expect(find.text('Blocked action'), findsOneWidget);
      expect(find.text('You’re Invited!'), findsNothing);
    },
  );
}
