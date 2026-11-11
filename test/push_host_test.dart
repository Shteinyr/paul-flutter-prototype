import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/live/live_chat_view.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/push/push_api.dart';
import 'package:paul_demo/push/push_browser_types.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';
import 'push_controller_test.dart'
    show Browser, Repository, user, session, canonical, proposed;
import 'support/quiet_chat_repository.dart';
import 'support/onboarding_preferences.dart';

const thread = '20000000-0000-4000-8000-000000000001';
const secondThread = '20000000-0000-4000-8000-000000000004';
const secondDelivery = '20000000-0000-4000-8000-000000000005';
const managed = '20000000-0000-4000-8000-000000000002';
const peerId = '20000000-0000-4000-8000-000000000003';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

class _Browser extends Browser {
  final events = StreamController<PushClick>.broadcast();
  PushClick? initial;
  @override
  Stream<PushClick> get clicks => events.stream;
  @override
  PushClick? takeClick() => initial;
}

class _Push extends Repository {
  String kind = 'chat';
  bool forbidden = false;
  int resolves = 0;
  Completer<PushRoute>? pendingRoute;
  @override
  Future<PushRoute> resolve(PushClick click) async {
    resolves++;
    if (resolves == 1 && pendingRoute != null) return pendingRoute!.future;
    if (click.deliveryId == secondDelivery) {
      return const PushRoute('chat', secondThread, null);
    }
    if (forbidden) throw const PushException('push_forbidden');
    if (kind.startsWith('community')) {
      return PushRoute.community(
        thread,
        kind == 'community-unavailable' ? 'unavailable' : 'active',
      );
    }
    return PushRoute(kind, thread, kind == 'operator' ? managed : null);
  }
}

class _Chat extends QuietChatRepository {
  _Chat(super.client);
  int histories = 0;
  @override
  Future<List<ChatSummary>> list() async => const [
    ChatSummary(
      id: secondThread,
      peer: ChatPeer(
        id: peerId,
        name: 'Second Notification Peer',
        occupation: 'QA',
      ),
      lastSequence: 0,
      lastReadSequence: 0,
      unread: 0,
    ),
    ChatSummary(
      id: thread,
      peer: ChatPeer(id: peerId, name: 'Notification Peer', occupation: 'QA'),
      lastSequence: 0,
      lastReadSequence: 0,
      unread: 0,
    ),
  ];
  @override
  Future<ChatHistory> history(String id, {int? before, int? after}) async {
    histories++;
    return const ChatHistory([], 0);
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  for (final kind in [
    'chat',
    'operator',
    'revoked',
    'disabled',
    'other-account',
    'signed-out',
    'queued',
    'community',
    'community-unavailable',
    'community-stale',
  ]) {
    testWidgets(
      'notification click $kind uses fresh authorization and preserves identity',
      (tester) async {
        final browser = _Browser()
          ..state = const BrowserPushState(
            supported: true,
            permission: 'granted',
            bindingId: canonical,
            active: true,
          );
        final push = _Push()
          ..kind = kind == 'operator' || kind == 'disabled'
              ? 'operator'
              : kind.startsWith('community')
              ? kind
              : 'chat'
          ..forbidden = kind == 'revoked';
        var adminReads = 0;
        var operatorHistory = 0;
        var communityReads = 0;
        var feedReads = 0;
        final token =
            'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': user, 'session_id': session, 'aud': 'authenticated', 'role': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}))).replaceAll('=', '')}.signature';
        Map<String, dynamic> profile(String id) => {
          'id': id,
          'name': id == user ? 'Self QA' : 'Notification Peer',
          'occupation': 'QA',
          'summary': 'QA summary',
          'skills': ['Marketing'],
          'searching_skills': [],
          'avatar_path': null,
          'contact_count': 1,
        };
        final transport = MockClient((request) async {
          Object data;
          if (request.url.path.endsWith('/token')) {
            data = {
              'access_token': token,
              'refresh_token': 'test-only',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': user,
                'aud': 'authenticated',
                'created_at': DateTime.utc(2026).toIso8601String(),
                'app_metadata': {},
                'user_metadata': {},
              },
            };
          } else if (request.url.path.endsWith('/invitations')) {
            data = {
              'profile': profile(user),
              'contacts': [profile(peerId)],
            };
          } else if (request.url.path.endsWith('/community')) {
            final body = jsonDecode(request.body) as Map;
            if (body['action'] == 'feed') {
              feedReads++;
              return http.Response(
                jsonEncode({
                  'requests': [],
                  'next_cursor': null,
                  'server_now': DateTime.now().toUtc().toIso8601String(),
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            expect(body, {'action': 'get', 'request_id': thread});
            communityReads++;
            data = {
              'request': kind == 'community'
                  ? {
                      'id': thread,
                      'author': {
                        'id': peerId,
                        'name': 'Community Author',
                        'occupation': 'QA',
                        'avatar_path': null,
                      },
                      'skill': 'Marketing',
                      'message': 'Fresh request',
                      'is_author': false,
                      'created_at': DateTime.now().toUtc().toIso8601String(),
                      'expires_at': DateTime.now()
                          .toUtc()
                          .add(const Duration(days: 30))
                          .toIso8601String(),
                    }
                  : null,
            };
          } else if (request.url.path.endsWith('/admin')) {
            final action = (jsonDecode(request.body) as Map)['action'];
            if (action == 'context') {
              adminReads++;
              data = {
                'role': 'admin',
                'profiles': [
                  {
                    'id': managed,
                    'name': 'Managed QA',
                    'can_manage': false,
                    'can_reply': true,
                    'disabled_at': kind == 'disabled'
                        ? '2026-11-10T00:00:00Z'
                        : null,
                  },
                ],
              };
            } else if (action == 'inbox') {
              data = {
                'profile_disabled': false,
                'conversations': [
                  {
                    'id': thread,
                    'peer': {
                      'id': peerId,
                      'name': 'Notification Peer',
                      'occupation': 'QA',
                    },
                    'last_message_seq': 0,
                    'last_read_seq': 0,
                    'unread_count': 0,
                    'last_message': null,
                  },
                ],
              };
            } else if (action == 'history') {
              operatorHistory++;
              data = {'messages': [], 'last_message_seq': 0};
            } else {
              data = {};
            }
          } else {
            return http.Response('{}', 404);
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://push-test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        final chat = _Chat(client);
        try {
          if (kind != 'signed-out') {
            await client.auth.signInWithPassword(
              email: 'qa@example.invalid',
              password: 'test-only',
            );
          }
          if (kind == 'queued') push.pendingRoute = Completer<PushRoute>();
          browser.initial = kind == 'queued'
              ? null
              : PushClick(
                  kind == 'other-account' ? peerId : user,
                  canonical,
                  proposed,
                );
          await tester.pumpWidget(
            PaulLiveApp(
              client: client,
              appUrl: Uri.parse('https://test.invalid'),
              chatRepositoryFor: (_) => chat,
              draftPreferences: DraftPreferences(),
              pushBrowser: browser,
              pushRepositoryFor: (_, _) => push,
            ),
          );
          if (kind == 'signed-out') {
            for (
              var attempt = 0;
              attempt < 20 && find.text('Paul Galda').evaluate().isEmpty;
              attempt++
            ) {
              await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 50)),
              );
              await tester.pump();
            }
            expect(find.text('Paul Galda'), findsOneWidget);
          }
          await tester.pumpAndSettle();
          if (kind == 'queued') {
            browser.events.add(const PushClick(user, canonical, proposed));
            await tester.pump();
            expect(push.resolves, 1);
            browser.events.add(
              const PushClick(user, canonical, secondDelivery),
            );
            await tester.pump();
            push.pendingRoute!.complete(const PushRoute('chat', thread, null));
            await tester.pumpAndSettle();
            expect(
              tester
                  .widget<LiveChatView>(find.byType(LiveChatView))
                  .conversationId,
              secondThread,
            );
          }
          final allowed =
              kind == 'chat' || kind == 'operator' || kind == 'queued';
          expect(
            find.byType(LiveChatView),
            allowed ? findsOneWidget : findsNothing,
          );
          expect(
            push.resolves,
            kind == 'other-account' || kind == 'signed-out'
                ? 0
                : kind == 'queued'
                ? 2
                : 1,
          );
          expect(
            chat.histories,
            kind == 'chat' || kind == 'queued' ? greaterThan(0) : 0,
          );
          if (kind == 'operator') {
            expect(adminReads, greaterThan(0));
            expect(operatorHistory, greaterThan(0));
            expect(find.textContaining('Replying as'), findsOneWidget);
          }
          if (kind == 'disabled') {
            expect(adminReads, greaterThan(0));
            expect(operatorHistory, 0);
          }
          if (kind.startsWith('community')) {
            expect(communityReads, 1);
            expect(find.text('Hiring request'), findsOneWidget);
            expect(
              find.text('Message author'),
              kind == 'community' ? findsOneWidget : findsNothing,
            );
            if (kind != 'community') {
              expect(
                find.text('This request is no longer available.'),
                findsOneWidget,
              );
            }
          }
          if (kind == 'community') {
            await tester.pageBack();
            await tester.pumpAndSettle();
            expect(find.text('Hiring'), findsOneWidget);
            expect(find.text('No active requests yet'), findsOneWidget);
            expect(find.text('Network hiring'), findsNothing);
            expect(feedReads, greaterThan(0));
          }
          expect(browser.prompts, 0);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(client.dispose);
          await browser.events.close();
        }
      },
    );
  }
}
