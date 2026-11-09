import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/onboarding/onboarding_skills_step.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/profile_store.dart';
import 'package:paul_demo/profile/user_profile.dart';

class _MemoryStore implements ProfileStore {
  UserProfile value = UserProfile.empty;
  @override
  Future<UserProfile> read() async => value;
  @override
  Future<void> write(UserProfile profile) async => value = profile;
  @override
  Future<void> clear() async => value = UserProfile.empty;
}

void main() {
  testWidgets('P08 permits an empty list and keeps same-named offers', (
    tester,
  ) async {
    final controller = ProfileController(_MemoryStore());
    await controller.load();
    controller.addSkill('Product Design');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => OnboardingSkillsStep(
              controller: controller,
              input: '',
              searching: true,
              validate: true,
              onInputChanged: (_) {},
              onSaved: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('onboarding-add-skill')));
    await tester.pump();
    expect(find.text('Required'), findsNothing);
    await tester.enterText(
      find.byKey(const Key('onboarding-skill-input')),
      'Product Design',
    );
    await tester.tap(find.byKey(const Key('onboarding-add-skill')));
    await tester.pump();
    expect(controller.profile.searchingSkills, ['Product Design']);
    expect(controller.profile.skills, ['Product Design']);
    await tester.tap(find.byTooltip('Remove Product Design'));
    await tester.pump();
    expect(controller.profile.searchingSkills, isEmpty);
    expect(controller.profile.skills, ['Product Design']);
    await tester.pumpWidget(const SizedBox());
    await controller.flush();
    controller.dispose();
  });

  testWidgets('P07 adds, rejects duplicates and removes offered skills', (
    tester,
  ) async {
    final controller = ProfileController(_MemoryStore());
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => OnboardingSkillsStep(
              controller: controller,
              input: '',
              onInputChanged: (_) {},
              onSaved: () {},
            ),
          ),
        ),
      ),
    );
    final input = find.byKey(const Key('onboarding-skill-input'));
    await tester.enterText(input, '  Product   Design ');
    await tester.tap(find.byKey(const Key('onboarding-add-skill')));
    await tester.pump();
    expect(controller.profile.skills, ['Product Design']);
    await tester.enterText(input, 'product design');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Already added'), findsOneWidget);
    expect(controller.profile.skills, ['Product Design']);
    await tester.tap(find.byTooltip('Remove Product Design'));
    await tester.pump();
    expect(controller.profile.skills, isEmpty);
    await tester.pumpWidget(const SizedBox());
    await controller.flush();
    controller.dispose();
  });
}
