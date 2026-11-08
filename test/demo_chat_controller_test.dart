import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/chat/demo_chat_controller.dart';
import 'package:paul_demo/demo_contacts.dart';

class MemoryChatStore implements DemoChatStore {
  String? saved;
  bool failWrite = false;
  Completer<void>? gate;
  @override
  Future<String?> read() async => saved;
  @override
  Future<void> write(String value) async {
    await gate?.future;
    if (failWrite) throw StateError('Save failed');
    saved = value;
  }
}

void main() {
  test(
    'mutual messages connect once; disconnect requires a new exchange; state restores',
    () async {
      final store = MemoryChatStore();
      final chat = DemoChatController(
        store: store,
        replyDelay: const Duration(days: 1),
      );
      await chat.load();
      var connections = 0;
      chat.onConnected = () => connections++;
      final id = demoChatContact.id;
      expect(chat.contacts, hasLength(5));
      expect(chat.unreadCount, 1);
      expect(chat.send('self', 'Hello'), isFalse);
      expect(chat.send(id, '   '), isFalse);
      expect(chat.isConnected(id), isFalse);
      chat.open(id);
      expect(chat.unreadCount, 0);
      expect(chat.send(id, 'Hi! How are you?'), isTrue);
      expect(chat.contacts, hasLength(6));
      expect(connections, 1);
      chat.send(id, 'One more message');
      expect(connections, 1);
      chat.disconnect(id);
      expect(chat.isConnected(id), isFalse);
      chat.receive(id, 'New incoming message');
      expect(chat.isConnected(id), isFalse);
      chat.send(id, 'A new reply');
      expect(connections, 2);
      chat.close(id);
      chat.setNotifications(true);
      var notifications = 0;
      chat.onNotification = (_, _) => notifications++;
      chat.receive(id, 'Background message');
      chat.updateDraft(id, 'Unsent draft');
      expect(notifications, 1);
      expect(chat.unreadCount, 1);
      await chat.flush();
      final messages = chat.ensureConversation(id).messages.length;
      chat.dispose();

      final restored = DemoChatController(store: store);
      await restored.load();
      expect(restored.ensureConversation(id).messages, hasLength(messages));
      expect(restored.ensureConversation(id).draft, 'Unsent draft');
      expect(restored.isConnected(id), isTrue);
      expect(restored.notificationsEnabled, isTrue);
      expect(restored.notificationChoiceMade, isTrue);
      expect(restored.unreadCount, 1);
      restored.open(id);
      expect(restored.unreadCount, 0);
      await restored.flush();
      restored.dispose();
    },
  );

  test(
    'queued saves keep the latest message and failed saves can retry',
    () async {
      final store = MemoryChatStore();
      final chat = DemoChatController(
        store: store,
        replyDelay: const Duration(days: 1),
      );
      await chat.load();
      store.gate = Completer<void>();
      chat.send(demoChatContact.id, 'First');
      final first = chat.flush();
      chat.send(demoChatContact.id, 'Second');
      final second = chat.flush();
      store.gate!.complete();
      await Future.wait([first, second]);
      store.gate = null;
      store.failWrite = true;
      chat.updateDraft(demoChatContact.id, 'Keep this draft');
      await chat.flush();
      expect(chat.error, isNotNull);
      store.failWrite = false;
      await chat.flush();
      expect(chat.error, isNull);
      chat.dispose();
      final restored = DemoChatController(store: store);
      await restored.load();
      expect(
        restored.ensureConversation(demoChatContact.id).messages.last.text,
        'Second',
      );
      expect(
        restored.ensureConversation(demoChatContact.id).draft,
        'Keep this draft',
      );
      restored.dispose();
    },
  );

  test(
    'invalid saved chats are not overwritten or available for sending',
    () async {
      final store = MemoryChatStore()..saved = '{"version":99}';
      final chat = DemoChatController(store: store);
      await chat.load();
      expect(chat.loadFailed, isTrue);
      expect(chat.send(demoChatContact.id, 'Hello'), isFalse);
      expect(store.saved, '{"version":99}');
      chat.dispose();
    },
  );

  testWidgets(
    'simulated background replies update unread and are cancelled by disconnect',
    (tester) async {
      final chat = DemoChatController(
        replyDelay: const Duration(milliseconds: 100),
      );
      final id = demoContacts.first.id;
      chat.setNotifications(true);
      var notifications = 0;
      chat.onNotification = (_, _) => notifications++;
      chat.open(id);
      chat.send(id, 'Hello');
      chat.close(id);
      await tester.pump(const Duration(milliseconds: 120));
      expect(chat.ensureConversation(id).unread, 1);
      expect(notifications, 1);
      chat.send(id, 'Cancel this scheduled reply');
      chat.disconnect(id);
      final count = chat.ensureConversation(id).messages.length;
      await tester.pump(const Duration(milliseconds: 200));
      expect(chat.ensureConversation(id).messages, hasLength(count));
      expect(chat.isConnected(id), isFalse);
      chat.dispose();
    },
  );
}
