import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/app.dart';
import 'package:paul_demo/demo_connect.dart';
import 'package:paul_demo/profile/profile_controller.dart';

import 'profile_controller_test.dart' show MemoryProfileStore;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final font = FontLoader('NotoSans')
      ..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'));
    await font.load();
  });
  testWidgets(
    'QR and Connect demo handle permission choices, previews and navigation without changing the profile',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryProfileStore();
      final controller = ProfileController(store);
      await controller.load();
      controller.updateName('Paul Galda');
      controller.updateOccupation('Business Analyst');
      await controller.flush();
      final original = store.saved;
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(PaulDemoApp(controller: controller));

      await tester.tap(find.byKey(const Key('open-demo-qr')));
      await tester.pumpAndSettle();
      expect(find.text('Paul Galda'), findsOneWidget);
      expect(find.text('Business Analyst'), findsOneWidget);
      expect(find.byKey(const Key('demo-qr-image')), findsOneWidget);
      expect(find.text(demoInviteCode), findsOneWidget);
      expect(find.text('Demo invite'), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-connect')));
      await tester.pumpAndSettle();
      expect(find.text('Connect'), findsOneWidget);
      for (final name in demoAddressBook) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('Invite'), findsNWidgets(5));

      await tester.ensureVisible(find.byKey(const Key('invite-demo-0')));
      await tester.tap(find.byKey(const Key('invite-demo-0')));
      await tester.pumpAndSettle();
      expect(find.text('Access to Contacts'), findsOneWidget);
      await tester.tap(find.byKey(const Key('deny-demo-contacts')));
      await tester.pumpAndSettle();
      expect(find.text('Prepared'), findsNothing);
      await tester.tap(find.byKey(const Key('invite-demo-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('allow-demo-contacts')));
      await tester.pumpAndSettle();
      expect(find.text('Invite Alex Parker'), findsOneWidget);
      expect(
        find.text('Demo only. No invitation will be sent.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Prepared'), findsNothing);

      await tester.tap(find.byKey(const Key('invite-demo-0')));
      await tester.pumpAndSettle();
      expect(find.text('Access to Contacts'), findsNothing);
      await tester.tap(find.byKey(const Key('prepare-demo-invitation')));
      await tester.pumpAndSettle();
      expect(find.text('Prepared'), findsOneWidget);

      await tester.ensureVisible(
        find.byKey(const Key('share-demo-invitation')),
      );
      await tester.tap(find.byKey(const Key('share-demo-invitation')));
      await tester.pumpAndSettle();
      expect(find.text('Share invitation'), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy-demo-invitation')));
      await tester.pumpAndSettle();
      expect(copied, contains('Demo invitation'));
      expect(copied, contains(demoInviteCode));
      expect(copied, isNot(contains('http')));

      await tester.tap(find.byKey(const Key('profile-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('demo-qr-image')), findsOneWidget);
      await tester.tap(find.byKey(const Key('profile-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contacts-list')), findsOneWidget);
      await tester.tap(find.byKey(const Key('open-demo-qr')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('open-connect')));
      await tester.pumpAndSettle();
      expect(find.text('Prepared'), findsOneWidget);
      expect(store.saved, original);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
