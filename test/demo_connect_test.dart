import 'dart:async';
import 'dart:convert';

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
  testWidgets('open QR follows profile changes and return from Connect', (
    tester,
  ) async {
    final controller = ProfileController(MemoryProfileStore());
    addTearDown(controller.dispose);
    await controller.load();
    controller.updateName('Before');
    await controller.flush();
    await tester.pumpWidget(PaulDemoApp(controller: controller));
    await tester.tap(find.byKey(const Key('open-demo-qr')));
    await tester.pumpAndSettle();
    expect(find.text('Before'), findsOneWidget);

    final photo = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    controller.updateName('After');
    controller.updateOccupation('Product Designer');
    controller.updatePhoto(photo);
    await controller.flush();
    await tester.pumpAndSettle();
    expect(find.text('After'), findsOneWidget);
    expect(find.text('Before'), findsNothing);
    expect(find.text('Product Designer'), findsOneWidget);
    final avatar = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const Key('qr-scroll')),
        matching: find.byType(Image),
      ),
    );
    expect((avatar.image as MemoryImage).bytes, photo);

    await tester.tap(find.byKey(const Key('open-connect')));
    await tester.pumpAndSettle();
    controller.updateName('Latest');
    await controller.flush();
    await tester.tap(find.byKey(const Key('profile-back')));
    await tester.pumpAndSettle();
    expect(find.text('Latest'), findsOneWidget);
    expect(find.text(demoInviteCode), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('copy failure keeps invitation open and allows one retry', (
    tester,
  ) async {
    final controller = ProfileController(MemoryProfileStore());
    addTearDown(controller.dispose);
    await controller.load();
    controller.updateName('Paul Galda');
    await controller.flush();
    var attempts = 0;
    String? copied;
    var copyGate = Completer<void>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method != 'Clipboard.setData') return null;
        attempts++;
        if (attempts == 1) throw PlatformException(code: 'clipboard-denied');
        await copyGate.future;
        copied = (call.arguments as Map)['text'] as String;
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
    await tester.tap(find.byKey(const Key('open-connect')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-demo-invitation')));
    await tester.pumpAndSettle();
    final copy = find.byKey(const Key('copy-demo-invitation'));
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Could not copy invitation. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Share invitation'), findsOneWidget);
    expect(find.text('Demo invitation copied'), findsNothing);
    await tester.tap(copy);
    await tester.pump();
    expect(tester.widget<TextButton>(copy).onPressed, isNull);
    expect(attempts, 2);
    copyGate.complete();
    await tester.pumpAndSettle();
    expect(copied, contains(demoInviteCode));
    expect(find.text('Share invitation'), findsNothing);
    expect(find.text('Demo invitation copied'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    copyGate = Completer<void>();
    await tester.tap(find.byKey(const Key('share-demo-invitation')));
    await tester.pumpAndSettle();
    await tester.tap(copy);
    await tester.pump();
    await tester.tap(find.text('Close'));
    await tester.pump();
    copyGate.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('share-demo-invitation')), findsOneWidget);
    expect(find.text('Demo invitation copied'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
