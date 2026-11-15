import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/invitation_entry_view.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  void viewport(
    WidgetTester tester, {
    double width = 402,
    double height = 874,
  }) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'P06 shows original entry copy and source content positions without preview',
    (tester) async {
      viewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(onJoin: (_) {}, onSignIn: (_) {}),
        ),
      );
      expect(find.text('App Name'), findsOneWidget);
      expect(
        find.text(
          'Your CV looks fine... People just hiring their friends and relatives ',
        ),
        findsOneWidget,
      );
      expect(find.text('Entire invite code '), findsOneWidget);
      expect(find.text('Join'), findsOneWidget);
      expect(find.text('Already a member? Sign in'), findsOneWidget);
      expect(
        find.text(
          'By continuing, you agree to the Terms of Use and Privacy Policy.',
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('invitation-app-name'))),
        const Offset(74, 358),
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('invitation-join'))),
        const Offset(120, 699),
      );
      expect(
        tester.getSize(find.byKey(const Key('invitation-join'))),
        const Size(162, 42),
      );
      expect(find.text('Contacts'), findsNothing);
      expect(find.text('Hiring'), findsNothing);
      expect(find.text('Keep signed in'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(tester.takeException(), null);
    },
  );
  testWidgets(
    'P06 uses its compact source variant while the code field is focused',
    (tester) async {
      viewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(onJoin: (_) {}, onSignIn: (_) {}),
        ),
      );
      await tester.tap(find.byKey(const Key('invite-code-input')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invitation-slogan')), findsNothing);
      expect(
        tester.getTopLeft(find.byKey(const Key('invitation-app-name'))),
        const Offset(72, 183),
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('invitation-join'))),
        const Offset(120, 431),
      );
      expect(
        find.byType(Image),
        findsNothing,
      ); // Keyboard is owned by the OS, not a bitmap.
    },
  );
  testWidgets(
    'both Join and existing-member Sign in forward the manually entered code',
    (tester) async {
      viewport(tester);
      String? joined, signed;
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(
            onJoin: (code) => joined = code,
            onSignIn: (code) => signed = code,
            pendingCredential: 'opaque-existing-invitation',
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('invite-code-input')),
        '12345678',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('invitation-join')));
      await tester.pumpAndSettle();
      expect(joined, '12345678');
      expect(signed, null);
      await tester.tap(find.byKey(const Key('invitation-existing-member')));
      await tester.pumpAndSettle();
      expect(signed, '12345678');
    },
  );
  testWidgets(
    'an incoming QR credential remains opaque and is used only when manual input is empty',
    (tester) async {
      viewport(tester);
      String? signed;
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(
            onJoin: (_) {},
            onSignIn: (code) => signed = code,
            pendingCredential: 'opaque-existing-invitation',
          ),
        ),
      );
      expect(find.text('opaque-existing-invitation'), findsNothing);
      await tester.tap(find.byKey(const Key('invitation-existing-member')));
      await tester.pumpAndSettle();
      expect(signed, 'opaque-existing-invitation');
    },
  );
  testWidgets(
    'source Invalid code state preserves code and controls while a new edit is delegated',
    (tester) async {
      viewport(tester);
      String? edited;
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(
            onJoin: (_) {},
            onSignIn: (_) {},
            initialCode: '12345678',
            invalidCode: true,
            onCodeChanged: (value) => edited = value,
          ),
        ),
      );
      expect(find.text('Invalid code'), findsOneWidget);
      expect(find.text('12345678'), findsOneWidget);
      expect(
        tester
            .widget<ColoredBox>(
              find.byKey(const Key('invitation-code-underline')),
            )
            .color,
        const Color(0xFFFF645C),
      );
      await tester.enterText(
        find.byKey(const Key('invite-code-input')),
        '87654321',
      );
      expect(edited, '87654321');
      expect(find.text('Join'), findsOneWidget);
    },
  );
  testWidgets(
    'a new invitation link replaces the previous manual code without exposing its token',
    (tester) async {
      viewport(tester);
      String? submitted;
      Widget view(String? credential) => MaterialApp(
        home: InvitationEntryView(
          pendingCredential: credential,
          onJoin: (value) => submitted = value,
          onSignIn: (_) {},
        ),
      );
      await tester.pumpWidget(view(null));
      await tester.enterText(
        find.byKey(const Key('invite-code-input')),
        '00000000',
      );
      await tester.pumpWidget(view(null));
      expect(find.text('00000000'), findsOneWidget);
      final incoming = List.filled(64, 'a').join();
      await tester.pumpWidget(view(incoming));
      await tester.pumpAndSettle();
      expect(find.text('00000000'), findsNothing);
      expect(find.text(incoming), findsNothing);
      await tester.tap(find.byKey(const Key('invitation-join')));
      expect(submitted, incoming);
    },
  );
  testWidgets(
    'checking disables both callbacks without introducing Checking copy',
    (tester) async {
      viewport(tester);
      var actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(
            onJoin: (_) => actions++,
            onSignIn: (_) => actions++,
            checking: true,
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('invitation-join')));
      await tester.tap(find.byKey(const Key('invitation-existing-member')));
      expect(actions, 0);
      expect(find.text('Checking…'), findsNothing);
      expect(find.text('Join'), findsOneWidget);
    },
  );
  for (final width in [320.0, 390.0, 402.0]) {
    testWidgets('P06 can enter and submit a code without overflow at $width', (
      tester,
    ) async {
      viewport(tester, width: width, height: 844);
      String? entered;
      await tester.pumpWidget(
        MaterialApp(
          home: InvitationEntryView(
            onJoin: (code) => entered = code,
            onSignIn: (_) {},
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('invite-code-input')));
      await tester.enterText(
        find.byKey(const Key('invite-code-input')),
        '12345678',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('invitation-join')));
      await tester.tap(find.byKey(const Key('invitation-join')));
      await tester.pumpAndSettle();
      expect(entered, '12345678');
      expect(tester.takeException(), null);
    });
  }
}
