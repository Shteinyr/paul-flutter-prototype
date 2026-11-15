import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paul_demo/live/continue_setup_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/member_capabilities.dart';
import 'package:paul_demo/app.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'profile_controller_test.dart' show MemoryProfileStore;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  for (final count in [0, 1, 2, 9]) {
    testWidgets(
      'P15 uses the source milestone state for $count completed registrations',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ContinueSetupCard(
                  invitedRegistrations: count,
                  onInvite: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(count < 2 ? '1 of 3' : '2 of 3'), findsOneWidget);
        expect(find.text('10+ Connections'), findsOneWidget);
        expect(find.text('2+ Connections'), findsOneWidget);
        expect(find.text('Complete profile '), findsOneWidget);
        expect(find.text('Invite'), findsOneWidget);
        expect(
          find.text('Message anyone, anytime'),
          count < 2 ? findsOneWidget : findsNothing,
        );
        expect(
          find.text(
            'Offer unlimited skills & services\nOutreach offline community ',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining('Explorer jobs beyond your network'),
          findsNothing,
        );
        final origin = tester.getTopLeft(
          find.byKey(const Key('continue-setup-card')),
        );
        expect(
          tester.getSize(find.byKey(const Key('continue-setup-card'))),
          Size(314, count < 2 ? 423 : 400),
        );
        expect(
          tester.getTopLeft(find.byKey(const Key('continue-setup-title'))) -
              origin,
          const Offset(32, 37),
        );
        expect(
          tester.getTopLeft(find.byKey(const Key('continue-setup-track'))) -
              origin,
          const Offset(32, 74),
        );
        expect(
          tester.getSize(find.byKey(const Key('continue-setup-track'))),
          const Size(250, 11),
        );
        expect(
          tester.getSize(find.byKey(const Key('continue-setup-fill'))).width,
          closeTo(count < 2 ? 88.08988952636719 : 172, 0.001),
        );
        final button =
            tester.getTopLeft(find.byKey(const Key('continue-setup-invite'))) -
            origin;
        expect(button.dx, 87);
        expect(
          button.dy,
          closeTo(count < 2 ? 346.87646484375 : 319.38916015625, 0.001),
        );
        expect(tester.takeException(), null);
      },
    );
  }
  testWidgets(
    'P15 opens only on a blocked action and Invite returns the existing-flow intent',
    (tester) async {
      var invite = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  invite =
                      await showContinueSetupDialog(
                        context,
                        invitedRegistrations: 1,
                      ) ==
                      true;
                },
                child: const Text('Blocked action'),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Continue setup'), findsNothing);
      await tester.tap(find.text('Blocked action'));
      await tester.pumpAndSettle();
      expect(find.text('Continue setup'), findsOneWidget);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      expect(invite, true);
      expect(find.text('Continue setup'), findsNothing);
    },
  );
  testWidgets(
    'P15 introduces no completion popup at ten or more registrations',
    (tester) async {
      for (final count in [10, 11]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: ContinueSetupCard(
                  invitedRegistrations: count,
                  onInvite: () {},
                ),
              ),
            ),
          ),
        );
        expect(find.text('Continue setup'), findsNothing);
        expect(find.text('3 of 3'), findsNothing);
      }
    },
  );
  testWidgets(
    'offering-limit action requests P15 without an extra Invite friends link',
    (tester) async {
      final store = MemoryProfileStore()
        ..saved = const UserProfile(
          name: 'Paul',
          skills: ['A', 'B', 'C', 'D', 'E'],
        ).encode();
      final controller = ProfileController(store, offeringLimit: 5);
      await controller.load();
      var blocks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileEditor(
              controller: controller,
              onOfferingLimit: () => blocks++,
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const Key('skills-field')));
      await tester.enterText(find.byKey(const Key('skills-field')), 'F');
      await tester.ensureVisible(find.byKey(const Key('add-skill')));
      await tester.tap(find.byKey(const Key('add-skill')));
      await tester.pumpAndSettle();
      expect(blocks, 1);
      expect(controller.profile.skills.length, 5);
      expect(find.text('Invite friends'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets(
    'the legacy profile footer exposes no extra invitation controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberLevelStatus(
              capabilities: MemberCapabilities(
                invitedRegistrations: 0,
                canMessageAnyone: false,
                canPublishCommunity: false,
                offeringLimit: 5,
                newConversationsRemaining: 1,
                quotaResetsAt: DateTime.utc(2026),
              ),
              error: null,
              onRefresh: () {},
              onInvite: () {},
            ),
          ),
        ),
      );
      expect(find.text('Refresh invitation level'), findsNothing);
      expect(find.text('Invite friends'), findsNothing);
      expect(find.text('0 joined with your invitation'), findsNothing);
    },
  );
  testWidgets('ProfileEditor has no unsolicited skill catalogue button', (
    tester,
  ) async {
    final controller = ProfileController(MemoryProfileStore());
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ProfileEditor(controller: controller)),
      ),
    );
    expect(find.text('Skill catalogue source'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
