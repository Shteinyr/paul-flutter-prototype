import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/chat_controller.dart';
import 'package:paul_demo/live/live_chat_list.dart';
import 'package:paul_demo/live/live_chat_view.dart';

const _peer = ChatPeer(
  id: 'peer',
  name: 'Synthetic Peer',
  occupation: 'Designer',
);

class _Store implements ChatStateStore {
  String? value;
  bool failRead = false;
  @override
  Future<String?> read(String userId) async {
    if (failRead) throw StateError('Synthetic storage failure');
    return value;
  }

  @override
  Future<void> write(String userId, String state) async => value = state;
}

class _Repository implements ChatRepository {
  @override
  String? currentUserId = 'actor';
  final identities = StreamController<String?>.broadcast(sync: true);
  final signals = StreamController<String>.broadcast(sync: true);
  final server = <ChatMessage>[];
  final sends = <(String, String)>[];
  Future<ChatAcknowledgement> Function(String, String)? sending;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Stream<String> watch() => signals.stream;
  @override
  Future<List<ChatSummary>> list() async => [
    ChatSummary(
      id: 'chat',
      peer: _peer,
      lastSequence: server.length,
      lastReadSequence: 0,
      unread: 3,
    ),
  ];
  @override
  Future<String> open(String peerId) async => 'chat';
  @override
  Future<ChatHistory> history(String id, {int? before, int? after}) async {
    var items = server
        .where(
          (item) =>
              (before == null || item.sequence < before) &&
              (after == null || item.sequence > after),
        )
        .toList();
    if (items.length > 100) {
      items = after == null
          ? items.sublist(items.length - 100)
          : items.sublist(0, 100);
    }
    return ChatHistory(items, server.length);
  }

  ChatAcknowledgement acknowledge(String clientId, String text) {
    final item = ChatMessage(
      id: 'server-${server.length + 1}',
      conversationId: 'chat',
      sequence: server.length + 1,
      senderId: 'actor',
      clientMessageId: clientId,
      text: text,
      createdAt: DateTime.utc(2026),
    );
    server.add(item);
    return ChatAcknowledgement(item, replayed: false, connected: false);
  }

  @override
  Future<ChatAcknowledgement> send(
    String id,
    String clientId,
    String text,
  ) async {
    sends.add((clientId, text));
    return sending == null
        ? acknowledge(clientId, text)
        : sending!(clientId, text);
  }

  @override
  Future<void> read(String id, int through) async {}
  @override
  Future<void> disconnect(String peerId, String operationId) async {}
  Future<void> close() async {
    await identities.close();
    await signals.close();
  }
}

Future<void> _view(WidgetTester tester, LiveChatController controller) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LiveChatView(
        controller: controller,
        conversationId: 'chat',
        peer: _peer,
        ownAvatar: const Icon(Icons.person),
        peerAvatar: const Icon(Icons.face),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(
  WidgetTester tester,
  LiveChatController controller,
  _Repository repository,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await controller.flushDrafts();
  await repository.close();
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });

  testWidgets(
    'pending becomes sent only after server acknowledgement and retains newer typed draft',
    (tester) async {
      final repository = _Repository();
      final ack = Completer<ChatAcknowledgement>();
      repository.sending = (_, _) => ack.future;
      final controller = LiveChatController(
        repository,
        'actor',
        drafts: _Store(),
      );
      await controller.load();
      await controller.openConversation('chat');
      await _view(tester, controller);
      await tester.enterText(
        find.byKey(const Key('live-chat-message-field')),
        'First message',
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-live-chat-message')));
      await tester.pump();
      expect(find.text('Sending…'), findsOneWidget);
      expect(find.text('Sent'), findsNothing);
      expect(repository.sends, hasLength(1));
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('send-live-chat-message')))
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('live-chat-message-field')),
        'Newer draft',
      );
      final (id, text) = repository.sends.single;
      ack.complete(repository.acknowledge(id, text));
      await tester.pumpAndSettle();
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Sending…'), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('live-chat-message-field')))
            .controller!
            .text,
        'Newer draft',
      );
      await _close(tester, controller, repository);
    },
  );

  testWidgets('failed row retries its exact operation and payload once', (
    tester,
  ) async {
    final repository = _Repository()
      ..sending = (_, _) async => throw StateError('Synthetic offline');
    final controller = LiveChatController(
      repository,
      'actor',
      drafts: _Store(),
    );
    await controller.load();
    await controller.openConversation('chat');
    await _view(tester, controller);
    await tester.enterText(
      find.byKey(const Key('live-chat-message-field')),
      'Exact payload  ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('send-live-chat-message')));
    await tester.pumpAndSettle();
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Sent'), findsNothing);
    final initial = repository.sends.single;
    repository.sending = null;
    await tester.tap(find.text('Retry message'));
    await tester.pumpAndSettle();
    expect(repository.sends, [initial, initial]);
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Not sent'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('live-chat-message-field')))
          .controller!
          .text,
      isEmpty,
    );
    await _close(tester, controller, repository);
  });

  testWidgets('journal read failure disables sending until explicit recovery', (
    tester,
  ) async {
    final repository = _Repository();
    final store = _Store()..failRead = true;
    final controller = LiveChatController(repository, 'actor', drafts: store);
    await controller.load();
    await _view(tester, controller);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('live-chat-message-field')))
          .enabled,
      false,
    );
    expect(repository.sends, isEmpty);
    store.failRead = false;
    await tester.tap(find.text('Retry chat'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('live-chat-message-field')))
          .enabled,
      true,
    );
    expect(repository.sends, isEmpty);
    await _close(tester, controller, repository);
  });

  testWidgets(
    'identity replacement removes private peer text and ignores late acknowledgement',
    (tester) async {
      final repository = _Repository();
      final ack = Completer<ChatAcknowledgement>();
      repository.sending = (_, _) => ack.future;
      final controller = LiveChatController(
        repository,
        'actor',
        drafts: _Store(),
      );
      await controller.load();
      await controller.openConversation('chat');
      await _view(tester, controller);
      await tester.enterText(
        find.byKey(const Key('live-chat-message-field')),
        'Private pending',
      );
      await tester.pump();
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-live-chat-message')));
      await tester.pump();
      repository.currentUserId = 'other-account';
      repository.identities.add('other-account');
      await tester.pumpAndSettle();
      final (id, text) = repository.sends.single;
      ack.complete(repository.acknowledge(id, text));
      await tester.pumpAndSettle();
      expect(find.text('Private pending'), findsNothing);
      expect(find.text('Synthetic Peer'), findsNothing);
      expect(find.text('Sent'), findsNothing);
      expect(find.text('Please sign in again to continue.'), findsOneWidget);
      await _close(tester, controller, repository);
    },
  );

  testWidgets(
    'chat list uses server roster and unread count and clears on identity loss',
    (tester) async {
      final repository = _Repository();
      final controller = LiveChatController(
        repository,
        'actor',
        drafts: _Store(),
      );
      await controller.load();
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveChatList(
              controller: controller,
              onOpen: (thread) => selected = thread.id,
              avatarFor: (_) => const Icon(Icons.person),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Synthetic Peer'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      await tester.tap(find.text('Synthetic Peer'));
      expect(selected, 'chat');
      repository.currentUserId = null;
      repository.identities.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Synthetic Peer'), findsNothing);
      await _close(tester, controller, repository);
    },
  );
}
