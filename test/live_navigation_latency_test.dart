import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/live/guest_preview.dart';
import 'package:paul_demo/live/live_chat_view.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'support/onboarding_preferences.dart';
import 'support/quiet_chat_repository.dart';
import 'community_controller_test.dart' show CommunityRepo, request;

const _actor = '00000000-0000-4000-8000-000000000001';
const _peer = '00000000-0000-4000-8000-000000000002';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

class _Chat extends QuietChatRepository {
  _Chat(super.client);
  Completer<ChatHistory>? historyGate;
  Completer<void>? readGate;
  int opens = 0;
  int reads = 0;
  int readRequests = 0;
  int histories = 0;
  final item = ChatMessage(
    id: 'message',
    conversationId: 'chat',
    sequence: 1,
    senderId: _peer,
    clientMessageId: 'incoming',
    text: 'Existing Julia message',
    createdAt: DateTime.utc(2026),
  );
  @override
  Future<List<ChatSummary>> list() async => [
    ChatSummary(
      id: 'chat',
      peer: const ChatPeer(id: _peer, name: 'Julia', occupation: 'Designer'),
      lastSequence: 1,
      lastReadSequence: reads == 0 ? 0 : 1,
      unread: reads == 0 ? 1 : 0,
      lastMessage: item,
    ),
  ];
  @override
  Future<String> open(String peerId) async {
    opens++;
    return 'chat';
  }

  @override
  Future<ChatHistory> history(String id, {int? before, int? after}) async {
    histories++;
    if (historyGate != null) return historyGate!.future;
    return ChatHistory(after == 1 ? [] : [item], 1);
  }

  @override
  Future<void> read(String id, int through) async {
    readRequests++;
    if (readGate != null) await readGate!.future;
    reads++;
  }
}

class _Fixture {
  _Fixture({this.community}) {
    client = SupabaseClient(
      'https://test.supabase.co',
      'test-key',
      httpClient: MockClient((request) async {
        final body = request.body.isEmpty
            ? {}
            : jsonDecode(request.body) as Map;
        Object data = {};
        if (request.url.path.endsWith('/token')) {
          final claims = {
            'sub': _actor,
            'aud': 'authenticated',
            'role': 'authenticated',
            'session_id': sessionId,
            'exp':
                DateTime.now()
                    .add(const Duration(hours: 1))
                    .millisecondsSinceEpoch ~/
                1000,
          };
          data = {
            'access_token':
                'e30.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature',
            'refresh_token': 'local-only',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': _actor,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          };
        } else if (body['action'] == 'network') {
          networks++;
          if (networkGate != null) await networkGate!.future;
          if (failNetwork) throw StateError('Offline');
          data = {
            'profile': member ? profile(_actor, 'Paul') : null,
            'contacts': member ? [profile(_peer, peerName)] : [],
          };
        } else if (body['action'] == 'capabilities') {
          data = {
            'invited_registrations': 10,
            'can_message_anyone': true,
            'can_publish_community': true,
            'offering_limit': null,
            'new_conversations_remaining': null,
            'quota_resets_at': '2030-01-01T00:00:00Z',
          };
        }
        return http.Response(
          jsonEncode(data),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      isolate: _Json(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    chat = _Chat(client);
  }
  final CommunityRepository? community;
  late final SupabaseClient client;
  late final _Chat chat;
  int networks = 0;
  Completer<void>? networkGate;
  bool member = true;
  bool failNetwork = false;
  String sessionId = '20000000-0000-4000-8000-000000000001';
  String peerName = 'Julia';
  Map<String, Object> profile(String id, String name) => {
    'id': id,
    'name': name,
    'occupation': 'Designer',
    'summary': 'Local profile',
    'skills': ['Design'],
    'searching_skills': <String>[],
    'contact_count': 1,
  };
  Future<void> mount(WidgetTester tester, {bool settle = true}) async {
    await client.auth.signInWithPassword(
      email: 'local@example.invalid',
      password: 'test-only',
    );
    await tester.pumpWidget(
      PaulLiveApp(
        client: client,
        appUrl: Uri.parse('https://test.invalid'),
        draftPreferences: DraftPreferences(),
        chatRepositoryFor: (_) => chat,
        communityRepositoryFor: community == null ? null : (_) => community!,
      ),
    );
    if (settle) await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(client.dispose);
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  testWidgets(
    'Hiring starts before the first visit and joins its pending feed',
    (tester) async {
      final gate = Completer<CommunityPage>();
      var calls = 0;
      final repo = CommunityRepo()
        ..userId = _actor
        ..currentUserId = _actor;
      repo.feeding = (_) {
        calls++;
        return gate.future;
      };
      final f = _Fixture(community: repo);
      try {
        await f.mount(tester);
        expect(calls, 1);
        expect(find.text('Paul'), findsOneWidget);
        await tester.tap(find.byKey(const Key('tab-1')));
        await tester.pump();
        expect(calls, 1);
        gate.complete(CommunityPage([request()], null, DateTime.now().toUtc()));
        await tester.pumpAndSettle();
        expect(find.text('Author'), findsOneWidget);
        expect(find.text('Urgent Hiring:  Marketing'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) {
          gate.complete(CommunityPage([], null, DateTime.now().toUtc()));
        }
        await f.close(tester);
        await repo.identities.close();
      }
    },
  );

  testWidgets(
    'initial auth notification joins the already pending member load',
    (tester) async {
      final f = _Fixture()..networkGate = Completer<void>();
      try {
        await f.mount(tester, settle: false);
        await tester.pump();
        expect(f.networks, 1);
        f.networkGate!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Paul'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (f.networkGate?.isCompleted == false) f.networkGate!.complete();
        await f.close(tester);
      }
    },
  );

  testWidgets('returning to Contacts keeps the list visible during refresh', (
    tester,
  ) async {
    final f = _Fixture();
    try {
      await f.mount(tester);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      f.networkGate = Completer<void>();
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Paul'), findsOneWidget);
      expect(find.text('Julia'), findsOneWidget);
      f.peerName = 'Updated Julia';
      f.networkGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Updated Julia'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      if (f.networkGate?.isCompleted == false) f.networkGate!.complete();
      await f.close(tester);
    }
  });

  testWidgets('existing chat opens before history and read acknowledgement', (
    tester,
  ) async {
    final f = _Fixture();
    try {
      await f.mount(tester);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      f.chat.historyGate = Completer<ChatHistory>();
      f.chat.readGate = Completer<void>();
      await tester.tap(find.text('Julia'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LiveChatView), findsOneWidget);
      expect(f.chat.reads, 0);
      f.chat.historyGate!.complete(ChatHistory([f.chat.item], 1));
      await tester.pump();
      expect(find.text('Existing Julia message'), findsOneWidget);
      expect(f.chat.reads, 0);
      final refresh = tester
          .widget<LiveChatView>(find.byType(LiveChatView))
          .controller
          .refresh();
      await tester.pump();
      expect(f.chat.readRequests, 1);
      f.chat.readGate!.complete();
      await refresh;
      await tester.pumpAndSettle();
      expect(f.chat.reads, 1);
      expect(f.chat.opens, 0);
      expect(tester.takeException(), isNull);
    } finally {
      if (f.chat.historyGate?.isCompleted == false) {
        f.chat.historyGate!.complete(const ChatHistory([], 0));
      }
      if (f.chat.readGate?.isCompleted == false) f.chat.readGate!.complete();
      await f.close(tester);
    }
  });

  testWidgets('Contacts refresh coalesces and removes revoked membership', (
    tester,
  ) async {
    final f = _Fixture();
    try {
      await f.mount(tester);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      f.networkGate = Completer<void>();
      final before = f.networks;
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pump();
      expect(f.networks, before + 1);
      expect(find.text('Julia'), findsOneWidget);
      f.member = false;
      f.networkGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Paul'), findsNothing);
      expect(find.text('Julia'), findsNothing);
      expect(find.byType(GuestPreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      if (f.networkGate?.isCompleted == false) f.networkGate!.complete();
      await f.close(tester);
    }
  });

  testWidgets('failed Contacts refresh retains usable cards and can recover', (
    tester,
  ) async {
    final f = _Fixture();
    try {
      await f.mount(tester);
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      f.failNetwork = true;
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('Julia'), findsOneWidget);
      f.failNetwork = false;
      f.peerName = 'Recovered Julia';
      await tester.tap(find.byKey(const Key('tab-2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('Recovered Julia'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await f.close(tester);
    }
  });

  for (final leave in ['back', 'sign-out', 'new-session']) {
    testWidgets('late history cannot mark read after $leave', (tester) async {
      final f = _Fixture();
      try {
        await f.mount(tester);
        await tester.tap(find.byKey(const Key('tab-2')));
        await tester.pumpAndSettle();
        f.chat.historyGate = Completer<ChatHistory>();
        await tester.tap(find.text('Julia'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(LiveChatView), findsOneWidget);
        if (leave == 'back') {
          await tester.tap(find.byKey(const Key('profile-back')));
        } else if (leave == 'sign-out') {
          await f.client.auth.signOut(scope: SignOutScope.local);
        } else {
          f.sessionId = '20000000-0000-4000-8000-000000000002';
          await f.client.auth.signInWithPassword(
            email: 'local@example.invalid',
            password: 'test-only',
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        if (leave == 'back') {
          final views = find.byType(LiveChatView);
          if (views.evaluate().isNotEmpty) {
            expect(ModalRoute.of(tester.element(views))!.isActive, isFalse);
          }
        } else {
          expect(find.byType(LiveChatView), findsNothing);
        }
        f.chat.historyGate!.complete(ChatHistory([f.chat.item], 1));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(f.chat.reads, 0);
        expect(find.text('Existing Julia message'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (f.chat.historyGate?.isCompleted == false) {
          f.chat.historyGate!.complete(const ChatHistory([], 0));
        }
        await f.close(tester);
      }
    });
  }
}
