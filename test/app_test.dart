import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/app.dart';
import 'package:paul_demo/demo_contacts.dart';
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
    'profile editing, photo changes, contacts and deletion work together',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final photo = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      );
      final store = MemoryProfileStore();
      final controller = ProfileController(store);
      await controller.load();
      await tester.pumpWidget(
        PaulDemoApp(controller: controller, pickPhoto: () async => photo),
      );
      expect(find.byKey(const Key('contact-row')), findsNothing);
      expect(find.text('Maya Chen'), findsOneWidget);

      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('name-field')),
        'Julia Robinson',
      );
      await tester.enterText(
        find.byKey(const Key('occupation-field')),
        'UI/UX Designer',
      );
      await tester.tap(find.byKey(const Key('choose-photo')));
      await tester.pumpAndSettle();
      expect(controller.profile.photo, photo);

      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('Julia Robinson'), findsOneWidget);
      expect(find.text('UI/UX Designer'), findsOneWidget);
      expect(find.byKey(const Key('contact-row')), findsOneWidget);
      final contactImage = tester.widget<Image>(
        find.descendant(
          of: find.byKey(const Key('contact-row')),
          matching: find.byType(Image),
        ),
      );
      expect((contactImage.image as MemoryImage).bytes, photo);
      expect(find.text('Maya Chen'), findsOneWidget);
      expect(demoContacts.length, 5);
      await tester.tap(find.byKey(const Key('contact-row')));
      await tester.pumpAndSettle();
      expect(find.text('Julia Robinson'), findsOneWidget);
      expect(find.text('UI/UX Designer'), findsOneWidget);
      await tester.tap(find.byKey(const Key('edit-public-profile')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('occupation-field')),
        'Product Designer',
      );
      await tester.tap(find.byKey(const Key('remove-photo')));
      await tester.pumpAndSettle();
      expect(controller.profile.photo, isNull);
      expect(controller.profile.name, 'Julia Robinson');
      await tester.tap(find.byKey(const Key('choose-photo')));
      await tester.pumpAndSettle();
      expect(controller.profile.photo, photo);

      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.profile.hasData, isTrue);
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contact-row')), findsNothing);
      expect(store.saved, isNull);
      expect(controller.profile.hasData, isFalse);
      expect(find.text('Maya Chen'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('photo picker cancellation keeps the current profile', (
    tester,
  ) async {
    final controller = ProfileController(MemoryProfileStore());
    await controller.load();
    await tester.pumpWidget(
      PaulDemoApp(controller: controller, pickPhoto: () async => null),
    );
    await tester.tap(find.byKey(const Key('tab-3')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('name-field')), 'Julia');
    await tester.tap(find.byKey(const Key('choose-photo')));
    await tester.pumpAndSettle();
    expect(controller.profile.name, 'Julia');
    expect(controller.profile.photo, isNull);
    await controller.flush();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('small viewport and keyboard keep the form usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.reset);
    final controller = ProfileController(MemoryProfileStore());
    await controller.load();
    await tester.pumpWidget(
      PaulDemoApp(controller: controller, pickPhoto: () async => null),
    );
    await tester.tap(find.byKey(const Key('tab-3')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('occupation-field')));
    await tester.enterText(
      find.byKey(const Key('occupation-field')),
      'Engineer',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await controller.flush();
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets(
    'Next profile supports summary, both skill lists and validation',
    (tester) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryProfileStore();
      final controller = ProfileController(store);
      await controller.load();
      await tester.pumpWidget(
        PaulDemoApp(controller: controller, pickPhoto: () async => null),
      );
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('name-field')),
        'Alex Morgan',
      );
      await tester.enterText(
        find.byKey(const Key('occupation-field')),
        'Mobile Developer',
      );
      await tester.ensureVisible(find.byKey(const Key('summary-field')));
      await tester.enterText(
        find.byKey(const Key('summary-field')),
        'I build useful apps for growing businesses.',
      );
      await tester.ensureVisible(find.byKey(const Key('add-skill')));
      await tester.tap(find.byKey(const Key('add-skill')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('personal-skills')),
          matching: find.text('Required'),
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byKey(const Key('skills-field')), 'Flutter');
      await tester.tap(find.byKey(const Key('add-skill')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('skills-field')), 'Dart');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(controller.profile.skills, ['Flutter', 'Dart']);
      await tester.enterText(find.byKey(const Key('skills-field')), 'flutter');
      await tester.tap(find.byKey(const Key('add-skill')));
      await tester.pumpAndSettle();
      expect(find.text('Already added'), findsOneWidget);
      expect(controller.profile.skills, ['Flutter', 'Dart']);
      await tester.tap(find.byTooltip('Remove Dart'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('searching-skills-field')),
      );
      await tester.enterText(
        find.byKey(const Key('searching-skills-field')),
        'Photography',
      );
      await tester.ensureVisible(find.byKey(const Key('add-searching-skill')));
      await tester.tap(find.byKey(const Key('add-searching-skill')));
      await tester.pumpAndSettle();
      expect(controller.profile.skills, ['Flutter']);
      expect(controller.profile.searchingSkills, ['Photography']);
      await controller.flush();
      final saved = await store.read();
      expect(saved.summary, 'I build useful apps for growing businesses.');
      expect(saved.skills, ['Flutter']);
      expect(saved.searchingSkills, ['Photography']);
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('Alex Morgan'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('view-own-profile')));
      await tester.tap(find.byKey(const Key('view-own-profile')));
      await tester.pumpAndSettle();
      expect(
        find.text('I build useful apps for growing businesses.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('edit-public-profile')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Remove Photography'));
      await tester.tap(find.byTooltip('Remove Photography'));
      await tester.pumpAndSettle();
      expect(controller.profile.searchingSkills, isEmpty);
      await tester.ensureVisible(find.byKey(const Key('add-searching-skill')));
      await tester.tap(find.byKey(const Key('add-searching-skill')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('searching-skills')),
          matching: find.text('Required'),
        ),
        findsNothing,
      );
      await controller.flush();
      expect((await store.read()).searchingSkills, isEmpty);
      expect(controller.profile.skills, ['Flutter']);
      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(controller.profile.hasData, isFalse);
      expect(store.saved, isNull);
      expect(find.text('Maya Chen'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'failed deletion retries confirmation and save failures retry edits',
    (tester) async {
      tester.view.physicalSize = const Size(402, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final store = MemoryProfileStore();
      final controller = ProfileController(store);
      addTearDown(controller.dispose);
      await controller.load();
      controller.updateName('P02 Reviewer');
      controller.updateSummary('Original summary');
      await controller.flush();
      store.failDelete = true;
      await tester.pumpWidget(PaulDemoApp(controller: controller));
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(controller.profile.name, 'P02 Reviewer');
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect((await store.read()).summary, 'Original summary');

      store.failWrite = true;
      await tester.ensureVisible(find.byKey(const Key('summary-field')));
      await tester.enterText(
        find.byKey(const Key('summary-field')),
        'Edited summary after failed deletion',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      store.failWrite = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsNothing);
      expect(
        (await store.read()).summary,
        'Edited summary after failed deletion',
      );
      expect(controller.error, isNull);

      await tester.ensureVisible(find.byKey(const Key('delete-account')));
      await tester.tap(find.byKey(const Key('delete-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      store.failDelete = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Delete account?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-delete')));
      await tester.pumpAndSettle();
      expect(controller.profile.hasData, isFalse);
      expect(store.saved, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'all five contacts open full profiles and both skill lists on a small screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ProfileController(MemoryProfileStore());
      await controller.load();
      await tester.pumpWidget(PaulDemoApp(controller: controller));
      expect(demoContacts, hasLength(5));
      for (final contact in demoContacts) {
        final row = find.byKey(Key('demo-contact-${contact.id}'));
        await tester.ensureVisible(row);
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('Public Profile'), findsOneWidget);
        expect(find.text(contact.name), findsOneWidget);
        expect(find.text(contact.occupation), findsOneWidget);
        expect(find.text(contact.summary), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.byKey(const Key('edit-public-profile')), findsNothing);
        for (final section in ['offered', 'searching']) {
          final more = find.byKey(Key('see-more-$section'));
          await tester.ensureVisible(more);
          await tester.tap(more);
          await tester.pumpAndSettle();
          final skills = section == 'offered'
              ? contact.skills
              : contact.searchingSkills;
          expect(find.byKey(Key('all-$section-skills')), findsOneWidget);
          for (final skill in skills) {
            expect(find.text(skill), findsOneWidget);
          }
          await tester.tap(find.byKey(const Key('profile-back')));
          await tester.pumpAndSettle();
          expect(find.text(contact.name), findsOneWidget);
        }
        await tester.tap(find.byKey(const Key('profile-back')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('contacts-list')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(controller.profile.hasData, isFalse);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets(
    'photo activates required markers without shifting the optional searching field',
    (tester) async {
      tester.view.physicalSize = const Size(402, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final image = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
      );
      final controller = ProfileController(MemoryProfileStore());
      await controller.load();
      await tester.pumpWidget(
        PaulDemoApp(controller: controller, pickPhoto: () async => image),
      );
      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(
        find.byKey(const Key('searching-skills-field')),
      );
      expect(find.text('Required'), findsNothing);
      await tester.tap(find.byKey(const Key('choose-photo')));
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsNWidgets(4));
      expect(
        find.descendant(
          of: find.byKey(const Key('searching-skills')),
          matching: find.text('Required'),
        ),
        findsNothing,
      );
      expect(
        tester.getTopLeft(find.byKey(const Key('searching-skills-field'))),
        before,
      );
      expect(tester.takeException(), isNull);
      await controller.flush();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
