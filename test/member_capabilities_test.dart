import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/chat_controller.dart';
import 'package:paul_demo/live/live_chat_view.dart';
import 'package:paul_demo/live/member_capabilities.dart';
import 'package:paul_demo/live/continue_setup_dialog.dart';
import 'package:paul_demo/onboarding/onboarding_flow.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/user_profile.dart';

import 'live_chat_controller_test.dart' show Repository, Drafts;
import 'profile_controller_test.dart' show MemoryProfileStore;
import 'support/onboarding_preferences.dart';

MemberCapabilities _level(int count) => MemberCapabilities.fromJson({
  'invited_registrations': count,
  'can_message_anyone': count >= 2,
  'can_publish_community': count >= 10,
  'offering_limit': count >= 10 ? null : 5,
  'new_conversations_remaining': count >= 2 ? null : 1,
  'quota_resets_at': '2026-11-12T00:00:00Z',
});

void main() {
  for (final count in [0, 1, 2, 9, 10]) {
    test('offering policy follows fresh level $count', () async {
      final level = _level(count);
      final controller = ProfileController(
        MemoryProfileStore(),
        offeringLimit: level.offeringLimit,
      );
      addTearDown(controller.dispose);
      await controller.load();
      for (var n = 0; n < 5; n++) {
        expect(controller.addSkill('Skill $n'), isTrue);
      }
      expect(controller.addSkill('Sixth skill'), count >= 10);
      expect(level.canMessageAnyone, count >= 2);
      expect(level.canPublishCommunity, count >= 10);
      await controller.flush();
      expect(controller.error, isNull);
    });
  }

  test(
    'legacy offerings survive unrelated saves and upgrade unlocks extension',
    () async {
      final store = MemoryProfileStore()
        ..saved = UserProfile(
          name: 'Legacy',
          skills: List.generate(8, (n) => 'Legacy $n'),
        ).encode();
      final controller = ProfileController(store, offeringLimit: 5);
      addTearDown(controller.dispose);
      await controller.load();
      controller.updateSummary('An unrelated edit');
      await controller.flush();
      expect((await store.read()).skills.length, 8);
      expect(controller.addSkill('New skill'), isFalse);
      controller.removeSkill('Legacy 7');
      await controller.flush();
      expect(controller.offeringLimit, 7);
      expect(controller.addSkill('New skill'), isFalse);
      controller.setOfferingLimit(_level(10).offeringLimit);
      expect(controller.addSkill('New skill'), isTrue);
      await controller.flush();
    },
  );

  testWidgets(
    'six restored onboarding offerings stop before sign-in without truncation',
    (tester) async {
      var completions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingFlow(
            initialDraft: UserProfile(
              skills: List.generate(6, (n) => 'Offered $n'),
            ),
            preferences: DraftPreferences(),
            onComplete: (_) async {
              completions++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('onboarding-complete')));
      await tester.tap(find.byKey(const Key('onboarding-complete')));
      await tester.pumpAndSettle();
      expect(find.text('Getting Started'), findsOneWidget);
      expect(
        find.text('Choose up to 5 offered skills before continuing.'),
        findsOneWidget,
      );
      expect(find.byTooltip('Remove Offered 5'), findsOneWidget);
      expect(completions, 0);
      await tester.ensureVisible(find.byTooltip('Remove Offered 5'));
      await tester.tap(find.byTooltip('Remove Offered 5'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
      expect(find.text('Searching Skills'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'daily quota rejection preserves the operation and offers an invitation',
    (tester) async {
      final repository = Repository()
        ..sending = (_, _) async =>
            throw const ChatException('new_contact_limit_reached');
      final controller = LiveChatController(repository, 'a', drafts: Drafts());
      var invited = false;
      var quotaEvents = 0;
      controller.onSendError = (error) {
        if (error.code == 'new_contact_limit_reached') quotaEvents++;
      };
      await controller.load();
      await controller.openConversation('chat');
      await tester.pumpWidget(
        MaterialApp(
          home: LiveChatView(
            controller: controller,
            conversationId: 'chat',
            peer: const ChatPeer(
              id: 'peer',
              name: 'External peer',
              occupation: '',
            ),
            ownAvatar: const Icon(Icons.person),
            peerAvatar: const Icon(Icons.person),
            onNewRecipientLimit: () async {
              if (await showContinueSetupDialog(
                    tester.element(find.byType(LiveChatView)),
                    invitedRegistrations: 0,
                  ) ==
                  true)
                invited = true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('live-chat-message-field')),
        'A preserved message',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-live-chat-message')));
      await tester.pumpAndSettle();
      expect(find.text('Continue setup'), findsOneWidget);
      expect(controller.pending('chat').single.text, 'A preserved message');
      final operation = controller.pending('chat').single.clientMessageId;
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      expect(invited, isTrue);
      expect(quotaEvents, 1);
      repository.sending = null;
      expect(await controller.retry('chat', operation), isTrue);
      expect(repository.sends.map((item) => item.$1).toSet(), {operation});
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await repository.identities.close();
      await repository.signals.close();
    },
  );
}
