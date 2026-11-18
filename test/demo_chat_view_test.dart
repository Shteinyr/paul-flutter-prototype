import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/app.dart';
import 'package:paul_demo/chat/demo_chat_controller.dart';
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
    'chat connects a new contact, clears unread, supports the keyboard, notifications and reversible connection removal',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = ProfileController(MemoryProfileStore());
      await controller.load();
      controller.updateName('Alex Morgan');
      controller.updateOccupation('Business Analyst');
      await controller.flush();
      final chat = DemoChatController(replyDelay: const Duration(days: 1));
      await tester.pumpWidget(
        PaulDemoApp(controller: controller, chatController: chat),
      );
      expect(find.text('Julia Robinson'), findsNothing);

      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsOneWidget);
      await tester.tap(find.byKey(const Key('enable-demo-push')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unread-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-thread-julia-robinson')));
      await tester.pumpAndSettle();
      expect(find.text('Hey, Welcome!'), findsOneWidget);
      expect(chat.unreadCount, 0);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('send-chat-message')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('chat-message-field')),
        'Hi! How are you?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-chat-message')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(chat.isConnected(demoChatContact.id), isTrue);
      expect(find.text('Hi! How are you?'), findsOneWidget);
      expect(find.text('You’re connected!'), findsOneWidget);
      expect(chat.isConnected(demoChatContact.id), isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('chat-message-field')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('profile-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unread-1')), findsNothing);
      await tester.tap(find.byKey(const Key('demo-chat-notification')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('unread-1')), findsOneWidget);
      expect(
        find.text('Julia Robinson: Hey! Ready to connect?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Hey! Ready to connect?'), findsOneWidget);
      expect(chat.unreadCount, 0);
      await tester.tap(find.byKey(const Key('profile-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contacts-list')), findsOneWidget);
      expect(chat.contacts.map((c) => c.id), contains(demoChatContact.id));
      await tester.scrollUntilVisible(
        find.byKey(const Key('demo-contact-julia-robinson')),
        150,
        scrollable: find.descendant(
          of: find.byKey(const Key('contacts-list')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('demo-contact-julia-robinson')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-profile-chat')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('delete-connection')));
      await tester.tap(find.byKey(const Key('delete-connection')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(chat.isConnected(demoChatContact.id), isTrue);
      await tester.tap(find.byKey(const Key('delete-connection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-delete-connection')));
      await tester.pumpAndSettle();
      expect(chat.isConnected(demoChatContact.id), isFalse);
      expect(chat.contacts, hasLength(5));
      expect(
        chat.ensureConversation(demoChatContact.id).messages,
        hasLength(3),
      );

      await tester.tap(find.byKey(const Key('tab-3')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('view-own-profile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('open-profile-chat')), findsNothing);
      expect(find.byKey(const Key('delete-connection')), findsNothing);
      expect(find.byKey(const Key('edit-public-profile')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      chat.dispose();
      controller.dispose();
    },
  );
}
