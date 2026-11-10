import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/chat_controller.dart';
import 'package:paul_demo/live/browser_storage.dart';

ChatMessage message(
  int seq, {
  String sender = 'a',
  String? actor,
  String? clientId,
  String text = 'Test',
}) => ChatMessage(
  id: 'message-$seq',
  conversationId: 'chat',
  sequence: seq,
  senderId: sender,
  actorUserId: actor,
  clientMessageId: clientId ?? 'client-$seq',
  text: text,
  createdAt: DateTime.utc(2026),
);

class Drafts implements ChatStateStore {
  final saved = <String, String>{};
  final writes = <String>[];
  Completer<String?>? gate;
  Completer<void>? writeGate;
  bool failWrites = false;
  @override
  Future<String?> read(String userId) async =>
      gate == null ? saved[userId] : gate!.future;
  @override
  Future<void> write(String userId, String drafts) async {
    if (writeGate != null) await writeGate!.future;
    if (failWrites) throw StateError('Storage failed');
    saved[userId] = drafts;
    writes.add(drafts);
  }
}

class Repository implements ChatRepository {
  @override
  String? currentUserId = 'a';
  final identities = StreamController<String?>.broadcast(sync: true);
  final signals = StreamController<String>.broadcast(sync: true);
  final server = <ChatMessage>[];
  final sends = <(String, String)>[];
  final afterCursors = <int?>[];
  final reads = <int>[];
  Future<ChatAcknowledgement> Function(String clientId, String text)? sending;
  Future<String> Function(String peerId)? opening;
  Future<ChatHistory> Function(String, int?, int?)? historyLoading;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Stream<String> watch() => signals.stream;
  @override
  Future<List<ChatSummary>> list() async => [];
  @override
  Future<String> open(String peerId) async =>
      opening == null ? 'chat' : opening!(peerId);
  @override
  Future<ChatHistory> history(String id, {int? before, int? after}) async {
    afterCursors.add(after);
    if (historyLoading != null) return historyLoading!(id, before, after);
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
    return ChatHistory(items, server.lastOrNull?.sequence ?? 0);
  }

  @override
  Future<ChatAcknowledgement> send(
    String conversationId,
    String clientMessageId,
    String text,
  ) async {
    sends.add((clientMessageId, text));
    if (sending != null) return sending!(clientMessageId, text);
    final item = message(
      server.length + 1,
      clientId: clientMessageId,
      text: text,
    );
    server.add(item);
    return ChatAcknowledgement(item, replayed: false, connected: false);
  }

  @override
  Future<void> read(String conversationId, int through) async {
    reads.add(through);
  }

  @override
  Future<void> disconnect(String peerId, String clientOperationId) async {}
  Future<void> close() async {
    await identities.close();
    await signals.close();
  }
}

void main() {
  late Repository repository;
  late Drafts drafts;
  late LiveChatController controller;
  setUp(() {
    repository = Repository();
    drafts = Drafts();
    controller = LiveChatController(repository, 'a', drafts: drafts);
  });
  tearDown(() async {
    controller.dispose();
    await controller.flushDrafts();
    await repository.close();
  });
  test(
    'session-store adapter retains reload state and isolates account keys',
    () async {
      final store = SessionChatStateStore();
      try {
        await store.write('store-a', 'A journal');
        await store.write('store-b', 'B journal');
        final reloaded = SessionChatStateStore();
        expect(await reloaded.read('store-a'), 'A journal');
        expect(await reloaded.read('store-b'), 'B journal');
      } finally {
        removeSessionValue('paul.live.chat.state.v1.store-a');
        removeSessionValue('paul.live.chat.state.v1.store-b');
      }
    },
  );
  test(
    'independent tab journals retain different operation IDs across reload with the same identity',
    () async {
      final tabOne = Drafts(), tabTwo = Drafts();
      repository.sending = (_, _) async => throw StateError('Offline');
      var one = LiveChatController(repository, 'a', drafts: tabOne);
      var two = LiveChatController(repository, 'a', drafts: tabTwo);
      try {
        await one.load();
        await two.load();
        await one.send('chat', 'Tab one payload');
        await two.send('chat', 'Tab two payload');
        await one.flushDrafts();
        await two.flushDrafts();
        final firstId = one.pending('chat').single.clientMessageId;
        final secondId = two.pending('chat').single.clientMessageId;
        expect(firstId, isNot(secondId));
        one.dispose();
        two.dispose();
        one = LiveChatController(repository, 'a', drafts: tabOne);
        two = LiveChatController(repository, 'a', drafts: tabTwo);
        await one.load();
        await two.load();
        expect(one.pending('chat').single.clientMessageId, firstId);
        expect(two.pending('chat').single.clientMessageId, secondId);
        expect(one.draft('chat'), 'Tab one payload');
        expect(two.draft('chat'), 'Tab two payload');
      } finally {
        one.dispose();
        two.dispose();
      }
    },
  );
  test(
    'copied opener journal retries the identical operation and payload',
    () async {
      await controller.load();
      repository.sending = (_, _) async => throw StateError('Response lost');
      await controller.send('chat', 'Copied opener payload');
      await controller.flushDrafts();
      final original = repository.sends.single;
      final copied = Drafts()..saved['a'] = drafts.saved['a']!;
      final child = LiveChatController(repository, 'a', drafts: copied);
      try {
        await child.load();
        repository.sending = (id, text) async => ChatAcknowledgement(
          message(1, clientId: id, text: text),
          replayed: true,
          connected: false,
        );
        expect(await child.send('chat', 'Copied opener payload'), true);
        expect(repository.sends.last, original);
      } finally {
        child.dispose();
        await child.flushDrafts();
      }
    },
  );
  test(
    'initial history failure recovers older-page availability from fetched sequence',
    () async {
      repository.server.addAll(
        List.generate(150, (index) => message(index + 1, sender: 'b')),
      );
      await controller.load();
      repository.historyLoading = (_, _, _) async =>
          throw StateError('Temporary history failure');
      await controller.openConversation('chat');
      repository.historyLoading = null;
      await controller.refresh();
      expect(controller.messages('chat'), hasLength(100));
      expect(controller.hasOlder('chat'), true);
      await controller.loadOlder();
      expect(controller.messages('chat'), hasLength(150));
      expect(controller.hasOlder('chat'), false);
    },
  );
  test(
    'auth stream network error preserves draft and actual identity loss clears private UI',
    () async {
      await controller.load();
      repository.sending = (_, _) async => throw StateError('Offline');
      await controller.send('chat', 'Keep private draft');
      repository.identities.addError(
        StateError('Session refresh network error'),
      );
      expect(controller.draft('chat'), 'Keep private draft');
      expect(controller.pending('chat'), hasLength(1));
      expect(controller.error, isNotNull);
      repository.identities.add('a');
      await controller.refresh();
      expect(controller.draft('chat'), 'Keep private draft');
      repository.currentUserId = null;
      repository.identities.addError(StateError('Identity unavailable'));
      expect(controller.draft('chat'), '');
      expect(controller.pending('chat'), isEmpty);
      expect(controller.loaded, false);
    },
  );
  test(
    'unreadable local journal blocks sending until it can be restored',
    () async {
      drafts.saved['a'] = '{broken';
      await controller.load();
      expect(controller.stateLoadFailed, true);
      expect(await controller.send('chat', 'Unsafe new operation'), false);
      expect(repository.sends, isEmpty);
    },
  );
  test(
    'acknowledgement atomically clears matching draft and retry journal',
    () async {
      await controller.load();
      expect(await controller.send('chat', 'Original'), true);
      await controller.flushDrafts();
      for (final serialized in drafts.writes) {
        final state = jsonDecode(serialized) as Map;
        final pending = (state['pending'] as Map)['chat'] as List? ?? [];
        if ((state['drafts'] as Map)['chat'] == 'Original') {
          expect(pending, isNotEmpty);
        }
      }
    },
  );
  test(
    'reload after lost acknowledgement retries the persisted operation ID',
    () async {
      await controller.load();
      repository.sending = (id, text) async {
        repository.server.add(message(1, clientId: id, text: text));
        throw StateError('Committed but response lost');
      };
      expect(await controller.send('chat', 'Original payload'), false);
      await controller.flushDrafts();
      final original = repository.sends.single;
      controller.dispose();
      controller = LiveChatController(repository, 'a', drafts: drafts);
      await controller.load();
      expect(controller.pending('chat').single.clientMessageId, original.$1);
      repository.sending = (id, text) async => ChatAcknowledgement(
        repository.server.single,
        replayed: true,
        connected: false,
      );
      expect(await controller.send('chat', 'Original payload'), true);
      expect(repository.sends.last, original);
      expect(repository.server, hasLength(1));
    },
  );
  test(
    'out-of-order history cannot overwrite another selected dialogue',
    () async {
      await controller.load();
      final old = Completer<ChatHistory>();
      repository.historyLoading = (id, before, after) => id == 'old-chat'
          ? old.future
          : Future.value(const ChatHistory([], 0));
      final earlier = controller.openConversation('old-chat');
      await controller.openConversation('new-chat');
      old.complete(ChatHistory([message(1)], 1));
      await earlier;
      expect(controller.activeConversationId, 'new-chat');
      expect(controller.messages('old-chat'), isEmpty);
      expect(controller.messages('new-chat'), isEmpty);
    },
  );
  test(
    'realtime after disposal cannot refresh state or notify listeners',
    () async {
      var changed = 0;
      final disposed = LiveChatController(repository, 'a', drafts: drafts)
        ..onChanged = () => changed++;
      await disposed.load();
      disposed.dispose();
      final before = changed;
      repository.signals.add('changed');
      await Future<void>.delayed(Duration.zero);
      expect(changed, before);
    },
  );
  test('account switch while journaling prevents transport entirely', () async {
    await controller.load();
    drafts.writeGate = Completer<void>();
    final sending = controller.send('chat', 'A private message');
    repository.currentUserId = 'b';
    repository.identities.add('b');
    drafts.writeGate!.complete();
    expect(await sending, false);
    expect(repository.sends, isEmpty);
  });
  test(
    'storage failure keeps retry state and prevents an unjournaled send',
    () async {
      await controller.load();
      drafts.failWrites = true;
      expect(await controller.send('chat', 'Keep this draft'), false);
      expect(repository.sends, isEmpty);
      expect(controller.pending('chat').single.delivery, ChatDelivery.failed);
      drafts.failWrites = false;
      expect(
        await controller.retry(
          'chat',
          controller.pending('chat').single.clientMessageId,
        ),
        true,
      );
      expect(repository.sends, hasLength(1));
    },
  );
  test(
    'reconnect catches up more than 100 messages using each actual page cursor',
    () async {
      repository.server.add(message(1, sender: 'b'));
      await controller.load();
      await controller.openConversation('chat');
      repository.server.addAll(
        List.generate(250, (index) => message(index + 2, sender: 'b')),
      );
      repository.afterCursors.clear();
      repository.signals.add('subscribed');
      await controller.refresh();
      expect(controller.messages('chat'), hasLength(251));
      expect(repository.afterCursors, containsAllInOrder([1, 101, 201]));
      expect(repository.reads.last, 251);
    },
  );
  test(
    'message remains pending until server acknowledgement and newer draft survives',
    () async {
      await controller.load();
      final gate = Completer<ChatAcknowledgement>();
      repository.sending = (_, _) => gate.future;
      final sending = controller.send('chat', 'First');
      await Future<void>.delayed(Duration.zero);
      expect(controller.messages('chat'), isEmpty);
      expect(controller.pending('chat').single.delivery, ChatDelivery.pending);
      controller.updateDraft('chat', 'Next draft');
      final clientId = repository.sends.single.$1;
      gate.complete(
        ChatAcknowledgement(
          message(1, clientId: clientId, text: 'First'),
          replayed: false,
          connected: false,
        ),
      );
      expect(await sending, true);
      expect(controller.messages('chat').single.text, 'First');
      expect(controller.pending('chat'), isEmpty);
      expect(controller.draft('chat'), 'Next draft');
    },
  );
  test('failed send retries the same ID and exact payload', () async {
    await controller.load();
    repository.sending = (_, _) async => throw StateError('Offline');
    expect(await controller.send('chat', '  Exact\ntext  '), false);
    final pending = controller.pending('chat').single;
    expect(pending.delivery, ChatDelivery.failed);
    expect(controller.draft('chat'), '  Exact\ntext  ');
    repository.sending = (id, text) async => ChatAcknowledgement(
      message(1, clientId: id, text: text),
      replayed: true,
      connected: false,
    );
    expect(await controller.retry('chat', pending.clientMessageId), true);
    expect(repository.sends[0], repository.sends[1]);
    expect(controller.messages('chat'), hasLength(1));
    expect(controller.pending('chat'), isEmpty);
    expect(controller.draft('chat'), '');
  });
  test(
    'late send after account switch cannot expose messages or trigger connection',
    () async {
      await controller.load();
      var connected = 0;
      controller.onConnected = (_) => connected++;
      final gate = Completer<ChatAcknowledgement>();
      repository.sending = (_, _) => gate.future;
      final sending = controller.send('chat', 'Private draft');
      await Future<void>.delayed(Duration.zero);
      repository.currentUserId = 'b';
      repository.identities.add('b');
      gate.complete(
        ChatAcknowledgement(message(1), replayed: false, connected: true),
      );
      expect(await sending, false);
      expect(controller.messages('chat'), isEmpty);
      expect(controller.pending('chat'), isEmpty);
      expect(controller.draft('chat'), '');
      expect(connected, 0);
      expect(await controller.send('chat', 'Other account'), false);
    },
  );
  test(
    'send acknowledgement ahead of catch-up cannot skip intervening messages',
    () async {
      repository.server.add(message(1, sender: 'b'));
      await controller.load();
      await controller.openConversation('chat');
      repository.sending = (id, text) async {
        repository.server.addAll([
          message(2, sender: 'b'),
          message(3, sender: 'b'),
          message(4, clientId: id, text: text),
        ]);
        return ChatAcknowledgement(
          repository.server.last,
          replayed: false,
          connected: false,
        );
      };
      expect(await controller.send('chat', 'Fourth'), true);
      expect(controller.messages('chat').map((item) => item.sequence), [
        1,
        2,
        3,
        4,
      ]);
      expect(repository.afterCursors, contains(1));
      expect(repository.reads.last, 4);
    },
  );
  test(
    'reconnect reconciles a persisted message whose acknowledgement was lost',
    () async {
      await controller.load();
      await controller.openConversation('chat');
      repository.sending = (id, text) async {
        repository.server.add(message(1, clientId: id, text: text));
        throw StateError('Acknowledgement lost');
      };
      expect(await controller.send('chat', 'Accepted on server'), false);
      expect(controller.pending('chat'), hasLength(1));
      repository.signals.add('subscribed');
      await controller.refresh();
      expect(controller.messages('chat'), hasLength(1));
      expect(controller.pending('chat'), isEmpty);
      expect(controller.draft('chat'), '');
      repository.signals.add('changed');
      await controller.refresh();
      expect(controller.messages('chat'), hasLength(1));
    },
  );
  test(
    'late open cannot replace a more recently selected conversation',
    () async {
      await controller.load();
      final old = Completer<String>();
      repository.opening = (peer) =>
          peer == 'old' ? old.future : Future.value('new-chat');
      final earlier = controller.openPeer('old');
      expect(await controller.openPeer('new'), 'new-chat');
      old.complete('old-chat');
      expect(await earlier, null);
      expect(controller.activeConversationId, 'new-chat');
    },
  );
  test(
    'live Unicode validation uses 2000 graphemes and rejects NUL and blank text',
    () async {
      await controller.load();
      for (final text in [' \n', 'bad\u0000text', 'e\u0301' * 2001]) {
        expect(await controller.send('chat', text), false);
      }
      final allowed = '👩🏽‍💻' * 2000;
      expect(await controller.send('chat', allowed), true);
      expect(repository.sends.single.$2, allowed);
    },
  );
  test(
    'draft typed during restore wins and persisted draft is scoped by identity',
    () async {
      drafts.gate = Completer<String?>();
      final loading = controller.load();
      controller.updateDraft('chat', 'Newest');
      drafts.gate!.complete(
        jsonEncode({
          'drafts': {'chat': 'Old'},
          'pending': {},
        }),
      );
      await loading;
      await controller.flushDrafts();
      expect(controller.draft('chat'), 'Newest');
      expect(jsonDecode(drafts.saved['a']!)['drafts']['chat'], 'Newest');
      expect(drafts.saved.containsKey('b'), false);
    },
  );
  test(
    'managed sender ACK retains real actor and cannot acknowledge another operator operation',
    () async {
      controller.dispose();
      controller = LiveChatController(
        repository,
        'a',
        senderProfileId: 'managed',
        drafts: drafts,
      );
      await controller.load();
      repository.sending = (clientId, text) async {
        repository.server.add(
          message(
            1,
            sender: 'managed',
            actor: 'b',
            clientId: clientId,
            text: text,
          ),
        );
        throw TimeoutException('Own ACK lost');
      };
      expect(await controller.send('chat', 'Manual draft'), false);
      final operation = controller.pending('chat').single.clientMessageId;
      await controller.openConversation('chat');
      expect(controller.messages('chat').single.actorUserId, 'b');
      expect(controller.pending('chat'), hasLength(1));
      expect(controller.draft('chat'), 'Manual draft');
      repository.server.add(
        message(
          2,
          sender: 'managed',
          actor: 'a',
          clientId: operation,
          text: 'Manual draft',
        ),
      );
      await controller.refresh();
      expect(controller.pending('chat'), isEmpty);
      expect(controller.draft('chat'), isEmpty);
      expect(repository.currentUserId, 'a');
    },
  );

  test(
    'managed ACK is accepted only for the initiating Auth actor and sender profile',
    () async {
      controller.dispose();
      controller = LiveChatController(
        repository,
        'a',
        senderProfileId: 'managed',
        drafts: drafts,
      );
      await controller.load();
      repository.sending = (clientId, text) async {
        final item = message(
          1,
          sender: 'managed',
          actor: 'a',
          clientId: clientId,
          text: text,
        );
        repository.server.add(item);
        return ChatAcknowledgement(item, replayed: false, connected: false);
      };
      expect(await controller.send('chat', 'Manual reply'), true);
      expect(controller.pending('chat'), isEmpty);
      expect(controller.messages('chat').single.senderId, 'managed');
      expect(controller.messages('chat').single.actorUserId, 'a');
      expect(repository.currentUserId, 'a');
    },
  );
  test(
    'read-only managed state blocks new sends without losing private history or creating pending operations',
    () async {
      controller.dispose();
      var allowed = false;
      controller = LiveChatController(
        repository,
        'a',
        senderProfileId: 'managed',
        drafts: drafts,
        canSend: () => allowed,
      );
      repository.server.add(message(1, sender: 'managed', actor: 'a'));
      await controller.load();
      await controller.openConversation('chat');
      expect(await controller.send('chat', 'Disabled draft'), false);
      expect(repository.sends, isEmpty);
      expect(controller.pending('chat'), isEmpty);
      expect(controller.messages('chat'), hasLength(1));
      allowed = true;
      expect(controller.canSend, true);
    },
  );
}
