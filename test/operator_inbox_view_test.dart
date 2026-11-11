import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/app.dart';
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
  String? identity = _actor;
  ChatPeer peer = _peer;
  int photoReads = 0;
  Future<Uint8List?> Function(ChatPeer)? loadPhoto;
  final identities = StreamController<String?>.broadcast(sync: true);
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
  String? get currentUserId => identity;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Future<Uint8List?> photo(ChatPeer peer) {
    photoReads++;
    return loadPhoto?.call(peer) ?? Future.value(null);
  }

  @override
  Stream<String> watch() => signals.stream;
  @override
  Future<List<ChatSummary>> list() async {
    listCalls++;
    disabled = serverDisabled;
    return [
      ChatSummary(
        id: 'thread',
        peer: peer,
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
    await identities.close();
    await super.dispose();
  }
}

void main() {
  Widget inbox(_Repository repository) => MaterialApp(
    home: OperatorInboxView(
      repository: repository,
      actorId: _actor,
      profile: const ManagedProfile(
        id: _managed,
        name: 'Managed sender',
        canManage: true,
        canReply: true,
      ),
    ),
  );

  ChatPeer peerPhoto(String? path, {bool deleted = false}) => ChatPeer(
    id: _peer.id,
    name: _peer.name,
    occupation: _peer.occupation,
    avatarPath: path,
    deletedAt: deleted ? DateTime.utc(2026) : null,
  );

  int savedPhotos(WidgetTester tester) => tester
      .widgetList<ProfileAvatar>(find.byType(ProfileAvatar))
      .where((avatar) => avatar.photo != null)
      .length;

  testWidgets(
    'operator inbox with null path resolves and reuses the peer photo',
    (tester) async {
      final photo = (await rootBundle.load(
        'assets/people/julia-robinson.png',
      )).buffer.asUint8List();
      final repository = _Repository(_Client())
        ..serverDisabled = false
        ..peer = peerPhoto(null)
        ..loadPhoto = (_) async => photo;
      await tester.pumpWidget(inbox(repository));
      await tester.pumpAndSettle();
      expect(savedPhotos(tester), 1);
      await tester.tap(find.text(_peer.name));
      await tester.pumpAndSettle();
      expect(find.text('Preserved incoming QA'), findsOneWidget);
      expect(savedPhotos(tester), 1);
      expect(repository.photoReads, 1);
      repository.peer = peerPhoto(null, deleted: true);
      repository.signals.add('changed');
      await tester.pumpAndSettle();
      expect(savedPhotos(tester), 0);
      expect(find.text('Deleted user'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final changeIdentity in [false, true]) {
    testWidgets(
      'late operator photo cannot outlive ${changeIdentity ? 'identity' : 'path'}',
      (tester) async {
        final photo = (await rootBundle.load(
          'assets/people/julia-robinson.png',
        )).buffer.asUint8List();
        final oldPhoto = Completer<Uint8List?>();
        final nextPhoto = Completer<Uint8List?>();
        final repository = _Repository(_Client())
          ..serverDisabled = false
          ..peer = peerPhoto('peer/old.png')
          ..loadPhoto = (peer) => peer.avatarPath!.endsWith('old.png')
              ? oldPhoto.future
              : nextPhoto.future;
        await tester.pumpWidget(inbox(repository));
        await tester.pumpAndSettle();
        expect(savedPhotos(tester), 0);
        if (changeIdentity) {
          repository.identity = 'another-operator';
          repository.identities.add(repository.identity);
        } else {
          repository.peer = peerPhoto('peer/new.png');
          repository.signals.add('changed');
        }
        await tester.pumpAndSettle();
        oldPhoto.complete(photo);
        await tester.pumpAndSettle();
        expect(savedPhotos(tester), 0);
        if (changeIdentity) {
          expect(
            find.text('Please sign in again to continue.'),
            findsOneWidget,
          );
        } else {
          nextPhoto.complete(photo);
          await tester.pumpAndSettle();
          expect(savedPhotos(tester), 1);
          expect(repository.photoReads, 2);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'rebuilt inbox keeps authorization bound to its active repository',
    (tester) async {
      final client = _Client();
      final first = _Repository(client)..serverDisabled = false;
      final replacement = _Repository(client)..serverDisabled = false;
      final selected = ValueNotifier<_Repository>(first);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        selected.dispose();
        if (!first.signals.isClosed) await first.dispose();
        if (!replacement.signals.isClosed) await replacement.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<_Repository>(
            valueListenable: selected,
            builder: (context, repository, _) => OperatorInboxView(
              repository: repository,
              actorId: _actor,
              profile: const ManagedProfile(
                id: _managed,
                name: 'Rebuilt managed QA',
                canManage: true,
                canReply: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore peer QA'));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('live-chat-message-field'));
      expect(tester.widget<TextField>(field).enabled, true);
      selected.value = replacement;
      await tester.pumpAndSettle();
      final previous = first.listCalls;
      first.serverDisabled = true;
      first.signals.add('changed');
      await tester.pumpAndSettle();
      expect(first.listCalls, greaterThan(previous));
      expect(first.disabled, true);
      expect(tester.widget<TextField>(field).enabled, false);
      expect(find.text('Profile disabled'), findsOneWidget);
      first.serverDisabled = false;
      first.signals.add('changed');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).enabled, true);
      expect(find.text('Profile disabled'), findsNothing);
      expect(find.text('Preserved incoming QA'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(first.signals.isClosed, true);
      expect(replacement.signals.isClosed, false);
    },
  );

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
