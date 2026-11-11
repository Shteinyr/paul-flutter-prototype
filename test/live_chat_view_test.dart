import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/chat_controller.dart';
import 'package:paul_demo/live/live_chat_list.dart';
import 'package:paul_demo/live/live_chat_view.dart';
import 'package:paul_demo/live/live_disconnect_dialog.dart';

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
  ChatPeer peer = _peer;
  final sends = <(String, String)>[];
  final removals = <(String, String)>[];
  Future<void> Function()? removing;
  Future<ChatAcknowledgement> Function(String, String)? sending;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Stream<String> watch() => signals.stream;
  @override
  Future<List<ChatSummary>> list() async => [
    ChatSummary(
      id: 'chat',
      peer: peer,
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
  Future<void> disconnect(String peerId, String operationId) async {
    removals.add((peerId, operationId));
    await removing?.call();
  }

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
    'open history refreshes a deleted peer and removes all send controls',
    (tester) async {
      final repository = _Repository();
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
        'Retained draft',
      );
      repository.peer = ChatPeer(
        id: _peer.id,
        name: 'Удалённый пользователь',
        occupation: '',
        deletedAt: DateTime.utc(2026, 11, 11),
      );
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Удалённый пользователь'), findsOneWidget);
      expect(find.byKey(const Key('live-chat-message-field')), findsNothing);
      expect(find.byKey(const Key('send-live-chat-message')), findsNothing);
      expect(await controller.send('chat', 'Late send'), isFalse);
      expect(repository.sends, isEmpty);
      expect(controller.draft('chat'), 'Retained draft');
      await _close(tester, controller, repository);
    },
  );

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

  testWidgets(
    'removal retry keeps its operation id and new confirmation creates a new id',
    (tester) async {
      final repository = _Repository()
        ..removing = () async =>
            throw StateError('Synthetic lost acknowledgement');
      bool? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Remove contact'),
                onPressed: () async => confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => LiveDisconnectDialog(
                    repository: repository,
                    peer: _peer,
                    userId: 'actor',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Remove contact'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-live-disconnect')));
      await tester.pumpAndSettle();
      expect(confirmed, isNull);
      expect(find.text('Retry removal'), findsOneWidget);
      final original = repository.removals.single;
      repository.removing = null;
      await tester.tap(find.byKey(const Key('confirm-live-disconnect')));
      await tester.pumpAndSettle();
      expect(confirmed, true);
      expect(repository.removals, [original, original]);
      await tester.tap(find.text('Remove contact'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-live-disconnect')));
      await tester.pumpAndSettle();
      expect(repository.removals.last.$1, 'peer');
      expect(repository.removals.last.$2, isNot(original.$2));
      await tester.pumpWidget(const SizedBox.shrink());
      await repository.close();
    },
  );

  testWidgets(
    'earlier history is reachable on a small screen and loads the missing page',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Repository();
      for (var seq = 1; seq <= 101; seq++) {
        repository.server.add(
          ChatMessage(
            id: 'history-$seq',
            conversationId: 'chat',
            sequence: seq,
            senderId: 'peer',
            clientMessageId: 'history-client-$seq',
            text: 'History message $seq',
            createdAt: DateTime.utc(2026),
          ),
        );
      }
      final controller = LiveChatController(
        repository,
        'actor',
        drafts: _Store(),
      );
      await controller.load();
      await controller.openConversation('chat');
      await _view(tester, controller);
      await tester.fling(
        find.byKey(const Key('live-chat-messages')),
        const Offset(0, 20000),
        10000,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('load-older-chat')));
      await tester.tap(find.byKey(const Key('load-older-chat')));
      await tester.pumpAndSettle();
      expect(controller.messages('chat'), hasLength(101));
      expect(controller.hasOlder('chat'), false);
      expect(tester.takeException(), isNull);
      await _close(tester, controller, repository);
    },
  );
  testWidgets(
    'operator chat shows intended managed sender and becomes read-only without hiding history',
    (tester) async {
      final repository = _Repository();
      final store = _Store();
      var allowed = false;
      final controller = LiveChatController(
        repository,
        'actor',
        senderProfileId: 'managed',
        canSend: () => allowed,
        drafts: store,
      );
      repository.server.addAll([
        ChatMessage(
          id: 'incoming',
          conversationId: 'chat',
          sequence: 1,
          senderId: 'peer',
          actorUserId: 'peer',
          clientMessageId: 'incoming-id',
          text: 'Incoming QA',
          createdAt: DateTime.utc(2026),
        ),
        ChatMessage(
          id: 'manual',
          conversationId: 'chat',
          sequence: 2,
          senderId: 'managed',
          actorUserId: 'actor',
          clientMessageId: 'manual-id',
          text: 'Manual managed QA',
          createdAt: DateTime.utc(2026),
        ),
      ]);
      await controller.load();
      await controller.openConversation('chat');
      await tester.pumpWidget(
        MaterialApp(
          home: LiveChatView(
            controller: controller,
            conversationId: 'chat',
            peer: _peer,
            ownAvatar: const Icon(Icons.person),
            peerAvatar: const Icon(Icons.face),
            replyingAs: 'Managed QA',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Replying as Managed QA'), findsOneWidget);
      expect(find.text('Manual managed QA'), findsOneWidget);
      expect(find.text('Incoming QA'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Profile disabled'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('live-chat-message-field')))
            .enabled,
        false,
      );
      allowed = true;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('live-chat-message-field')))
            .enabled,
        true,
      );
      await _close(tester, controller, repository);
    },
  );
}
