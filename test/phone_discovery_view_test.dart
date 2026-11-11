import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/contacts/phone_discovery_view.dart';

import 'deletion_controller_test.dart' show other;
import 'phone_discovery_controller_test.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  testWidgets(
    'disabled SMS provider is visible and invitations remain usable',
    (tester) async {
      final repo = PhoneRepo()
        ..sms = false
        ..value = phoneStatus(verified: false);
      var invites = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneDiscoveryView(
            repository: repo,
            actions: DiscoveryActions(),
            onProfile: (_) async {},
            onInvite: () => invites++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('SMS verification is being configured'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('discovery-phone')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Send verification code'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Invite friends'));
      expect(invites, 1);
      expect(repo.codes, 0);
      expect(repo.consents, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(repo.disposed, isTrue);
    },
  );

  testWidgets(
    'verified contact flow selects consent, checks explicit numbers and opens a result',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = PhoneRepo();
      final profiles = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneDiscoveryView(
            repository: repo,
            actions: DiscoveryActions()..canPickContacts = false,
            onProfile: (id) async => profiles.add(id),
            onInvite: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(repo.consents, isEmpty);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(repo.consents.single.$1, isTrue);
      await tester.scrollUntilVisible(
        find.byKey(const Key('discovery-manual-number')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byKey(const Key('discovery-manual-number')),
        '+12025550123',
      );
      await tester.ensureVisible(find.text('Add number'));
      await tester.tap(find.text('Add number'));
      await tester.pumpAndSettle();
      expect(repo.lookups, isEmpty);
      await tester.scrollUntilVisible(
        find.byKey(const Key('discovery-find')),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('discovery-find')));
      await tester.pumpAndSettle();
      expect(repo.lookups.single.$1, ['+12025550123']);
      await tester.scrollUntilVisible(
        find.text('View profile'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('View profile'));
      await tester.pumpAndSettle();
      expect(profiles, [other]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(repo.disposed, isTrue);
    },
  );
}
