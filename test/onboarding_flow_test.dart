import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/onboarding/onboarding_draft_store.dart';
import 'package:paul_demo/onboarding/onboarding_flow.dart';
import 'package:paul_demo/onboarding/onboarding_skills_step.dart';
import 'package:paul_demo/photo_picker.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:paul_demo/skills/skill_catalogue.dart';

import 'support/onboarding_preferences.dart';

Widget _app({
  required DraftPreferences preferences,
  required Future<void> Function(UserProfile) onComplete,
  UserProfile? initialDraft,
  PickProfilePhoto? pickPhoto,
  Key? flowKey,
}) => MaterialApp(
  theme: ThemeData(fontFamily: 'NotoSans'),
  home: OnboardingFlow(
    key: flowKey,
    preferences: preferences,
    initialDraft: initialDraft,
    pickPhoto: pickPhoto,
    onComplete: onComplete,
  ),
);

Future<UserProfile> _validProfile() async {
  final photo = await rootBundle.load('assets/people/paul-galda.png');
  return UserProfile(
    name: 'New Member',
    summary: 'I build thoughtful products.',
    photo: photo.buffer.asUint8List(),
    skills: const ['Flutter'],
  );
}

Future<void> _press(WidgetTester tester, String key) async {
  final button = find.byKey(Key(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shared catalogue adds independent offering and seeking skills', (
    tester,
  ) async {
    await tester.runAsync(() => SkillCatalogue.shared.suggest('marketing'));
    await tester.pumpWidget(
      _app(preferences: DraftPreferences(), onComplete: (_) async {}),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('onboarding-skill-input')),
      'marketing',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final suggestion = find.byKey(
      const ValueKey('catalogue-marketing analytics'),
    );
    expect(suggestion, findsOneWidget);
    await tester.ensureVisible(suggestion);
    await tester.tap(suggestion);
    await tester.pumpAndSettle();
    final controller = tester
        .widget<OnboardingSkillsStep>(find.byType(OnboardingSkillsStep))
        .controller;
    expect(controller.profile.skills, ['marketing analytics']);
    await _press(tester, 'onboarding-next');
    await tester.enterText(
      find.byKey(const Key('onboarding-skill-input')),
      'marketing',
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(suggestion);
    await tester.tap(suggestion);
    await tester.pumpAndSettle();
    expect(controller.profile.searchingSkills, ['marketing analytics']);
    await _press(tester, 'onboarding-back');
    await tester.tap(find.byTooltip('Remove marketing analytics'));
    await tester.pumpAndSettle();
    expect(controller.profile.skills, isEmpty);
    expect(controller.profile.searchingSkills, ['marketing analytics']);
  });

  testWidgets(
    'a late input callback keeps the skill list of its original step',
    (tester) async {
      final preferences = DraftPreferences();
      await OnboardingDraftStore(
        preferences: preferences,
      ).write(const UserProfile(skills: ['Flutter']));
      await tester.pumpWidget(
        _app(preferences: preferences, onComplete: (_) async {}),
      );
      await tester.pumpAndSettle();
      final offeredInputChanged = tester
          .widget<OnboardingSkillsStep>(find.byType(OnboardingSkillsStep))
          .onInputChanged;
      await _press(tester, 'onboarding-next');
      offeredInputChanged('Composing offering');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      final restored = OnboardingDraftStore(preferences: preferences);
      await restored.read();
      expect(restored.offeredInput, 'Composing offering');
      expect(restored.searchingInput, isEmpty);
    },
  );

  testWidgets(
    'cancelled sign-in, edits and host re-entry retain the newest local draft',
    (tester) async {
      final preferences = DraftPreferences();
      final submitted = await _validProfile();
      var exited = false;
      Widget host(Key key) => MaterialApp(
        home: OnboardingFlow(
          key: key,
          initialDraft: submitted,
          preferences: preferences,
          onBack: () => exited = true,
          onComplete: (_) async =>
              throw const OnboardingSubmissionException('Sign in cancelled.'),
        ),
      );
      await tester.pumpWidget(host(const ValueKey('original')));
      await tester.pumpAndSettle();
      await _press(tester, 'onboarding-complete');
      await tester.enterText(
        find.byKey(const Key('onboarding-name')),
        'Edited after cancellation',
      );
      await _press(tester, 'onboarding-back');
      await tester.enterText(
        find.byKey(const Key('onboarding-skill-input')),
        'Unadded seeking',
      );
      await _press(tester, 'onboarding-back');
      await tester.enterText(
        find.byKey(const Key('onboarding-skill-input')),
        'Unadded offering',
      );
      await _press(tester, 'onboarding-back');
      expect(exited, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(const ValueKey('re-entered')));
      await tester.pumpAndSettle();
      expect(find.text('Getting Started'), findsOneWidget);
      expect(find.text('Unadded offering'), findsOneWidget);
      await _press(tester, 'onboarding-next');
      expect(find.text('Unadded seeking'), findsOneWidget);
      await _press(tester, 'onboarding-next');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('onboarding-name')))
            .controller!
            .text,
        'Edited after cancellation',
      );
    },
  );

  testWidgets(
    'P09 explains overlong restored fields without losing their contents',
    (tester) async {
      final profile = (await _validProfile()).copyWith(name: 'a' * 121);
      await tester.pumpWidget(
        _app(
          preferences: DraftPreferences(),
          initialDraft: profile,
          onComplete: (_) async => fail('Overlong draft must not submit'),
        ),
      );
      await tester.pumpAndSettle();
      await _press(tester, 'onboarding-complete');
      expect(find.text('Use 120 characters or fewer.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('onboarding-name')))
            .controller!
            .text,
        profile.name,
      );
    },
  );

  testWidgets('P09 remains scrollable at 320 pixels with the keyboard open', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final preferences = DraftPreferences();
    await tester.pumpWidget(
      _app(
        preferences: preferences,
        initialDraft: await _validProfile(),
        onComplete: (_) async {},
      ),
    );
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('onboarding-summary')));
    await tester.enterText(
      find.byKey(const Key('onboarding-summary')),
      'A longer summary that remains editable on a small screen.',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('onboarding-complete')));
    expect(tester.takeException(), isNull);
    await _press(tester, 'onboarding-back');
    expect(find.text('Searching Skills'), findsOneWidget);
  });

  testWidgets(
    'successful registration retries only draft cleanup after storage failure',
    (tester) async {
      final preferences = DraftPreferences();
      final profile = await _validProfile();
      var calls = 0;
      await tester.pumpWidget(
        _app(
          preferences: preferences,
          initialDraft: profile,
          onComplete: (_) async {
            calls++;
            preferences.failWrite = true;
          },
        ),
      );
      await tester.pumpAndSettle();
      await _press(tester, 'onboarding-complete');
      expect(find.text('Registration complete.'), findsOneWidget);
      expect(find.byKey(const Key('onboarding-retry-cleanup')), findsOneWidget);
      preferences.failWrite = false;
      await _press(tester, 'onboarding-retry-cleanup');
      expect(calls, 1);
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).hasData,
        isFalse,
      );
      expect(find.byKey(const Key('onboarding-retry-cleanup')), findsNothing);
    },
  );

  testWidgets('P07 and P08 navigation retains both lists and unadded input', (
    tester,
  ) async {
    final preferences = DraftPreferences();
    await tester.pumpWidget(
      _app(preferences: preferences, onComplete: (_) async {}),
    );
    await tester.pumpAndSettle();
    await _press(tester, 'onboarding-next');
    expect(find.text('Required'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('onboarding-skill-input')),
      'Flutter',
    );
    await _press(tester, 'onboarding-add-skill');
    await tester.enterText(
      find.byKey(const Key('onboarding-skill-input')),
      'Unadded offering',
    );
    await _press(tester, 'onboarding-next');
    expect(find.text('Searching Skills'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('onboarding-skill-input')),
      'Photography',
    );
    await _press(tester, 'onboarding-back');
    expect(find.text('Unadded offering'), findsOneWidget);
    expect(find.text('Flutter'), findsOneWidget);
    await _press(tester, 'onboarding-next');
    expect(find.text('Photography'), findsOneWidget);
    await _press(tester, 'onboarding-next');
    expect(find.text('About You'), findsOneWidget);
    final stored = OnboardingDraftStore(preferences: preferences);
    expect((await stored.read()).searchingSkills, isEmpty);
    expect(stored.step, 2);
    expect(stored.searchingInput, 'Photography');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      _app(preferences: preferences, onComplete: (_) async {}),
    );
    await tester.pumpAndSettle();
    expect(find.text('About You'), findsOneWidget);
    await _press(tester, 'onboarding-back');
    expect(find.text('Photography'), findsOneWidget);
  });

  testWidgets(
    'P09 validates fields and retains photo on cancel and invalid file',
    (tester) async {
      final preferences = DraftPreferences();
      final profile = await _validProfile();
      var choice = 0;
      await tester.pumpWidget(
        _app(
          preferences: preferences,
          initialDraft: const UserProfile(skills: ['Flutter']),
          pickPhoto: () async {
            choice++;
            if (choice == 1) return profile.photo;
            if (choice == 2) return null;
            throw const PhotoSelectionException(
              'This image could not be opened.',
            );
          },
          onComplete: (_) async => fail('Invalid profile must not submit'),
        ),
      );
      await tester.pumpAndSettle();
      await _press(tester, 'onboarding-complete');
      expect(find.text('Required'), findsNWidgets(3));
      await _press(tester, 'onboarding-photo');
      final firstPhoto = (await OnboardingDraftStore(
        preferences: preferences,
      ).read()).photo;
      expect(firstPhoto, profile.photo);
      await _press(tester, 'onboarding-photo');
      await _press(tester, 'onboarding-photo');
      expect(find.text('This image could not be opened.'), findsOneWidget);
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).photo,
        firstPhoto,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'P09 keeps a draft after callback failure and clears only after success',
    (tester) async {
      final preferences = DraftPreferences();
      final profile = await _validProfile();
      var calls = 0;
      await tester.pumpWidget(
        _app(
          preferences: preferences,
          initialDraft: profile,
          onComplete: (draft) async {
            calls++;
            expect(draft.occupation, isEmpty);
            expect(draft.searchingSkills, isEmpty);
            if (calls == 1) {
              throw const OnboardingSubmissionException(
                'Sign in cancelled. Try again.',
              );
            }
          },
        ),
      );
      await tester.pumpAndSettle();
      await _press(tester, 'onboarding-complete');
      expect(find.text('Sign in cancelled. Try again.'), findsOneWidget);
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).name,
        profile.name,
      );
      await _press(tester, 'onboarding-complete');
      expect(calls, 2);
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).hasData,
        isFalse,
      );
      expect(find.text('Registration complete.'), findsOneWidget);
    },
  );

  testWidgets(
    'P09 blocks repeat submission while host finalization is pending',
    (tester) async {
      final gate = Completer<void>();
      final preferences = DraftPreferences();
      final profile = await _validProfile();
      var calls = 0;
      await tester.pumpWidget(
        _app(
          preferences: preferences,
          initialDraft: profile,
          onComplete: (_) async {
            calls++;
            await gate.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      final complete = find.byKey(const Key('onboarding-complete'));
      await tester.ensureVisible(complete);
      await tester.tap(complete);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.tap(complete);
      await tester.pump(const Duration(milliseconds: 20));
      expect(calls, 1);
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).name,
        profile.name,
      );
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).hasData,
        isFalse,
      );
    },
  );

  testWidgets(
    'save failure keeps current step and Retry retains entered skill',
    (tester) async {
      final preferences = DraftPreferences();
      await tester.pumpWidget(
        _app(preferences: preferences, onComplete: (_) async {}),
      );
      await tester.pumpAndSettle();
      preferences.failWrite = true;
      await tester.enterText(
        find.byKey(const Key('onboarding-skill-input')),
        'Flutter',
      );
      await _press(tester, 'onboarding-add-skill');
      await _press(tester, 'onboarding-next');
      expect(find.text('Getting Started'), findsOneWidget);
      expect(find.text('Flutter'), findsOneWidget);
      preferences.failWrite = false;
      await _press(tester, 'onboarding-retry-save');
      await _press(tester, 'onboarding-next');
      expect(find.text('Searching Skills'), findsOneWidget);
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).skills,
        ['Flutter'],
      );
    },
  );

  testWidgets(
    'host success after route disposal still clears the saved draft',
    (tester) async {
      final preferences = DraftPreferences();
      final gate = Completer<void>();
      final profile = await _validProfile();
      await tester.pumpWidget(
        _app(
          preferences: preferences,
          initialDraft: profile,
          onComplete: (_) => gate.future,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('onboarding-complete')));
      await tester.tap(find.byKey(const Key('onboarding-complete')));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpWidget(const SizedBox());
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        (await OnboardingDraftStore(preferences: preferences).read()).hasData,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
