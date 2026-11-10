import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/admin/operator_chat_api.dart';
import 'package:paul_demo/admin/operator_inbox_view.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Client extends Fake implements SupabaseClient {}

const _actor = 'restore-operator';
const _managed = 'restore-managed';
const _peer = ChatPeer(id: 'peer', name: 'Restore peer QA', occupation: 'QA');

class _Repository extends OperatorChatApi {
  _Repository(SupabaseClient client)
    : super(SupabaseAdminApi(client, _actor), _managed);
  bool serverDisabled = true;
  int listCalls = 0;
  int sends = 0;
  final signals = StreamController<String>.broadcast();
  final messages = <ChatMessage>[
    ChatMessage(
      id: 'incoming',
      conversationId: 'thread',
      sequence: 1,
      senderId: 'peer',
      clientMessageId: 'incoming',
      text: 'Preserved incoming QA',
      createdAt: DateTime.utc(2026),
    ),
  ];
  @override
  String? get currentUserId => _actor;
  @override
  Stream<String?> get identityChanges => const Stream.empty();
  @override
  Stream<String> watch() => signals.stream;
  @override
  Future<List<ChatSummary>> list() async {
    listCalls++;
    disabled = serverDisabled;
    return [
      ChatSummary(
        id: 'thread',
        peer: _peer,
        lastSequence: messages.length,
        lastReadSequence: 0,
        unread: 1,
      ),
    ];
  }

  @override
  Future<ChatHistory> history(String id, {int? before, int? after}) async =>
      ChatHistory(
        messages
            .where((item) => after == null || item.sequence > after)
            .toList(),
        messages.length,
      );
  @override
  Future<void> read(String conversationId, int through) async {}
  @override
  Future<ChatAcknowledgement> send(
    String id,
    String clientMessageId,
    String text,
  ) async {
    sends++;
    final item = ChatMessage(
      id: 'manual',
      conversationId: id,
      sequence: messages.length + 1,
      senderId: _managed,
      actorUserId: _actor,
      clientMessageId: clientMessageId,
      text: text,
      createdAt: DateTime.utc(2026),
    );
    messages.add(item);
    return ChatAcknowledgement(item, replayed: false, connected: false);
  }

  @override
  Future<void> dispose() async {
    await signals.close();
    await super.dispose();
  }
}

void main() {
  testWidgets(
    'mounted disabled history becomes send-ready after restoration hint and fresh inbox',
    (tester) async {
      final client = _Client();
      final repository = _Repository(client);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: OperatorInboxView(
            repository: repository,
            actorId: _actor,
            profile: ManagedProfile(
              id: _managed,
              name: 'Restore managed QA',
              canManage: true,
              canReply: true,
              disabledAt: DateTime.utc(2026),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore peer QA'));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('live-chat-message-field'));
      expect(tester.widget<TextField>(field).enabled, false);
      expect(find.text('Preserved incoming QA'), findsOneWidget);
      repository.serverDisabled = false;
      repository.signals.add('changed');
      await tester.pumpAndSettle();
      expect(repository.listCalls, greaterThanOrEqualTo(2));
      expect(repository.disabled, false);
      expect(tester.widget<TextField>(field).enabled, true);
      await tester.enterText(field, 'Restored manual QA');
      await tester.pump();
      await tester.tap(find.byKey(const Key('send-live-chat-message')));
      await tester.pumpAndSettle();
      expect(repository.sends, 1);
      expect(find.text('Restored manual QA'), findsOneWidget);
      expect(find.text('Preserved incoming QA'), findsOneWidget);
    },
  );
}
