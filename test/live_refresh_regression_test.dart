import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/community/community_controller.dart';
import 'package:paul_demo/community/community_views.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/chat_controller.dart';
import 'package:paul_demo/live/live_chat_list.dart';
import 'package:paul_demo/live/live_disconnect_dialog.dart';

import 'community_controller_test.dart' show CommunityRepo;
import 'live_chat_controller_test.dart' show Drafts, Repository;

const _emptyChat = 'Open a contact’s profile to start a conversation.';
const _peer = ChatPeer(id: 'b', name: 'Peer', occupation: 'Designer');

class _ChatRepository extends Repository {
  var listing = Completer<List<ChatSummary>>();
  final removal = Completer<void>();
  int removals = 0;

  @override
  Future<List<ChatSummary>> list() => listing.future;

  @override
  Future<void> disconnect(String peerId, String operationId) async {
    removals++;
    await removal.future;
  }
}

CommunityRequest _request(String id, DateTime created, {DateTime? expires}) =>
    CommunityRequest(
      id: id,
      author: _peer,
      skill: 'Design',
      message: 'Request $id',
      createdAt: created,
      expiresAt: expires ?? created.add(const Duration(days: 30)),
      isAuthor: false,
    );

Widget _feed(CommunityController controller) => MaterialApp(
  home: CommunityFeedView(
    controller: controller,
    onMessage: (_, _) async {},
    onInvite: () {},
    avatarFor: (_) => const SizedBox.square(dimension: 65),
  ),
);

Future<void> _disposeFeed(
  WidgetTester tester,
  CommunityController controller,
  CommunityRepo repository,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  controller.dispose();
  await repository.identities.close();
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });

  testWidgets('Chat waits for its first server list before showing empty', (
    tester,
  ) async {
    final repository = _ChatRepository();
    final controller = LiveChatController(repository, 'a', drafts: Drafts());
    await controller.prepare();
    controller.resume();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveChatList(
            controller: controller,
            onOpen: (_) {},
            avatarFor: (_) => const SizedBox(),
          ),
        ),
      ),
    );
    expect(
      controller.loaded,
      isTrue,
      reason: 'Local journal is already ready.',
    );
    expect(find.text(_emptyChat), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.listing.complete([]);
    await tester.pumpAndSettle();
    expect(find.text(_emptyChat), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await repository.close();
  });

  testWidgets(
    'failed first Chat list shows retry without claiming it is empty',
    (tester) async {
      final repository = _ChatRepository();
      final controller = LiveChatController(repository, 'a', drafts: Drafts());
      await controller.prepare();
      controller.resume();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveChatList(
              controller: controller,
              onOpen: (_) {},
              avatarFor: (_) => const SizedBox(),
            ),
          ),
        ),
      );
      repository.listing.completeError(StateError('Network unavailable'));
      await tester.pumpAndSettle();
      expect(find.text('Retry chats'), findsOneWidget);
      expect(find.text(_emptyChat), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      repository.listing = Completer<List<ChatSummary>>();
      await tester.tap(find.text('Retry chats'));
      await tester.pump();
      repository.listing.complete([]);
      await tester.pumpAndSettle();
      expect(find.text(_emptyChat), findsOneWidget);
      expect(find.text('Retry chats'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await repository.close();
    },
  );

  for (final dismissal in ['Cancel', 'Back', 'Barrier', 'Escape']) {
    testWidgets('pending disconnect blocks $dismissal until acknowledged', (
      tester,
    ) async {
      final repository = _ChatRepository();
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => LiveDisconnectDialog(
                      repository: repository,
                      peer: _peer,
                      userId: 'a',
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-live-disconnect')));
      await tester.pump();
      switch (dismissal) {
        case 'Cancel':
          expect(
            tester
                .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
                .onPressed,
            isNull,
          );
          await tester.tap(find.text('Cancel'));
        case 'Back':
          await tester.binding.handlePopRoute();
        case 'Barrier':
          await tester.tapAt(const Offset(10, 10));
        case 'Escape':
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pumpAndSettle();
      expect(find.text('Removing…'), findsOneWidget);
      expect(result, isNull);
      expect(repository.removals, 1);
      repository.removal.complete();
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byType(LiveDisconnectDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await repository.close();
    });
  }

  testWidgets(
    'disconnect failure restores Cancel and keeps dialog recoverable',
    (tester) async {
      final repository = _ChatRepository();
      bool? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => LiveDisconnectDialog(
                      repository: repository,
                      peer: _peer,
                      userId: 'a',
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-live-disconnect')));
      await tester.pump();
      repository.removal.completeError(StateError('Lost acknowledgement'));
      await tester.pumpAndSettle();
      expect(find.text('Retry removal'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await repository.close();
    },
  );

  testWidgets('30 second Hiring refresh preserves older pages and cursor', (
    tester,
  ) async {
    final now = tester.binding.clock.now().toUtc();
    final first = _request('first', now);
    final older = _request('older', now.subtract(const Duration(hours: 1)));
    final repository = CommunityRepo();
    final cursors = <Map<String, dynamic>?>[];
    repository.feeding = (cursor) async {
      cursors.add(cursor);
      return CommunityPage(
        cursor == null ? [first] : [older],
        cursor == null ? {'id': 'older'} : {'id': 'next'},
        tester.binding.clock.now().toUtc(),
      );
    };
    final controller = CommunityController(
      repository,
      drafts: Drafts(),
      now: () => tester.binding.clock.now(),
    );
    await tester.pumpWidget(_feed(controller));
    await tester.pumpAndSettle();
    await controller.loadMore();
    await tester.pump();
    expect(controller.requests.map((item) => item.id), ['first', 'older']);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(controller.requests.map((item) => item.id), ['first', 'older']);
    expect(controller.hasMore, isTrue);
    expect(cursors, [
      null,
      {'id': 'older'},
      null,
      {'id': 'older'},
    ]);
    await _disposeFeed(tester, controller, repository);
  });

  testWidgets(
    'authoritative range refresh removes closed rows and sorts ties',
    (tester) async {
      final now = tester.binding.clock.now().toUtc();
      final a = _request('a', now);
      final z = _request('z', now);
      final older = _request('older', now.subtract(const Duration(hours: 1)));
      final oldest = _request('oldest', now.subtract(const Duration(hours: 2)));
      var refreshed = false;
      final repository = CommunityRepo()
        ..feeding = (cursor) async => CommunityPage(
          cursor == null ? [z, a] : (refreshed ? [oldest] : [older, oldest]),
          cursor == null ? {'id': 'second'} : null,
          now,
        );
      final controller = CommunityController(
        repository,
        drafts: Drafts(),
        now: () => now,
      );
      await controller.refresh();
      await controller.loadMore();
      refreshed = true;
      await controller.refresh();
      expect(controller.requests.map((item) => item.id), ['z', 'a', 'oldest']);
      expect(controller.hasMore, isFalse);
      controller.dispose();
      await repository.identities.close();
    },
  );

  testWidgets(
    'failed second range page retains displayed pages and retry cursor',
    (tester) async {
      final now = tester.binding.clock.now().toUtc();
      final first = _request('first', now);
      final older = _request('older', now.subtract(const Duration(hours: 1)));
      var fail = false;
      final repository = CommunityRepo()
        ..feeding = (cursor) async {
          if (cursor != null && fail) throw StateError('Second page offline');
          return CommunityPage(
            cursor == null ? [first] : [older],
            cursor == null ? {'id': 'older'} : {'id': 'next'},
            now,
          );
        };
      final controller = CommunityController(
        repository,
        drafts: Drafts(),
        now: () => now,
      );
      await controller.refresh();
      await controller.loadMore();
      fail = true;
      await controller.refresh();
      expect(controller.requests.map((item) => item.id), ['first', 'older']);
      expect(controller.hasMore, isTrue);
      expect(controller.error, isNotNull);
      controller.dispose();
      await repository.identities.close();
    },
  );

  testWidgets(
    'expired Hiring row hides at server boundary without another fetch',
    (tester) async {
      final clock = tester.binding.clock;
      final server = clock.now().toUtc().add(const Duration(hours: 3));
      final repository = CommunityRepo();
      var calls = 0;
      repository.feeding = (_) async {
        calls++;
        return CommunityPage(
          [
            _request(
              'expires',
              server,
              expires: server.add(const Duration(seconds: 2)),
            ),
          ],
          null,
          server,
        );
      };
      final controller = CommunityController(
        repository,
        drafts: Drafts(),
        now: clock.now,
      );
      await tester.pumpWidget(_feed(controller));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('community-expires')), findsOneWidget);
      final remaining = controller.requests.single.expiresAt.difference(
        controller.serverNow,
      );
      await tester.pump(remaining - const Duration(milliseconds: 1));
      expect(find.byKey(const ValueKey('community-expires')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(const ValueKey('community-expires')), findsNothing);
      expect(controller.requests, isEmpty);
      expect(calls, 1);
      await _disposeFeed(tester, controller, repository);
      await tester.pump(const Duration(seconds: 30));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Hiring detail hides body and action exactly at expiry', (
    tester,
  ) async {
    final clock = tester.binding.clock;
    final now = clock.now().toUtc();
    final repository = CommunityRepo()
      ..item = _request(
        'detail',
        now,
        expires: now.add(const Duration(seconds: 2)),
      );
    final controller = CommunityController(
      repository,
      drafts: Drafts(),
      now: clock.now,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityDetailView(
          controller: controller,
          requestId: 'detail',
          onMessage: (_, _) async {},
          avatarFor: (_) => const SizedBox.square(dimension: 65),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Request detail'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Request detail'), findsNothing);
    expect(find.text('Message author'), findsNothing);
    expect(find.text('This request is no longer available.'), findsOneWidget);
    await _disposeFeed(tester, controller, repository);
    await tester.pump(const Duration(seconds: 30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Hiring expiry is enforced immediately on resume', (
    tester,
  ) async {
    final clock = tester.binding.clock;
    var device = clock.now().toUtc();
    final repository = CommunityRepo()
      ..item = _request(
        'resume',
        device,
        expires: device.add(const Duration(seconds: 2)),
      );
    final controller = CommunityController(
      repository,
      drafts: Drafts(),
      now: () => device,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityDetailView(
          controller: controller,
          requestId: 'resume',
          onMessage: (_, _) async {},
          avatarFor: (_) => const SizedBox.square(dimension: 65),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    device = device.add(const Duration(seconds: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Message author'), findsNothing);
    expect(find.text('This request is no longer available.'), findsOneWidget);
    await _disposeFeed(tester, controller, repository);
  });
  for (final arrivals in [1, 20, 100]) {
    testWidgets(
      'Hiring refresh preserves the visible row with $arrivals new items',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final clock = tester.binding.clock;
        final now = clock.now().toUtc();
        final items = [
          for (var i = 0; i < 30; i++)
            _request('item-$i', now.subtract(Duration(minutes: i))),
        ];
        final repository = CommunityRepo()
          ..feeding = (cursor) async {
            final start = cursor?['offset'] as int? ?? 0;
            final end = (start + 10).clamp(0, items.length);
            return CommunityPage(
              items.sublist(start, end),
              end < items.length ? {'offset': end} : null,
              clock.now().toUtc(),
            );
          };
        final controller = CommunityController(
          repository,
          drafts: Drafts(),
          now: clock.now,
        );
        await tester.pumpWidget(_feed(controller));
        await tester.pumpAndSettle();
        await controller.loadMore();
        await tester.pumpAndSettle();
        final row = find.byKey(const ValueKey('community-item-7'));
        await tester.scrollUntilVisible(row, 200);
        await tester.pumpAndSettle();
        final top = tester.getTopLeft(row).dy;
        items.insertAll(0, [
          for (var index = arrivals; index > 0; index--)
            _request('new-$index', now.add(Duration(seconds: index))),
        ]);
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(controller.requests.any((item) => item.id == 'item-19'), isTrue);
        expect(controller.requests.first.id, 'new-$arrivals');
        expect(tester.getTopLeft(row).dy, closeTo(top, .5));
        expect(tester.takeException(), isNull);
        await _disposeFeed(tester, controller, repository);
      },
    );
  }

  testWidgets('close acknowledgement invalidates an in-flight range refresh', (
    tester,
  ) async {
    final now = tester.binding.clock.now().toUtc();
    final first = _request('first', now);
    final older = _request('older', now.subtract(const Duration(hours: 1)));
    final repository = CommunityRepo();
    Completer<CommunityPage>? gate;
    repository.feeding = (cursor) async {
      if (cursor != null && gate != null) return gate.future;
      return CommunityPage(
        cursor == null ? [first] : [older],
        cursor == null ? {'id': 'second'} : null,
        now,
      );
    };
    final controller = CommunityController(
      repository,
      drafts: Drafts(),
      now: () => now,
    );
    await controller.refresh();
    await controller.loadMore();
    gate = Completer<CommunityPage>();
    final refreshing = controller.refresh();
    await tester.pump();
    expect(await controller.closeRequest('older'), isTrue);
    gate.complete(CommunityPage([older], null, now));
    await refreshing;
    expect(controller.requests.map((item) => item.id), ['first']);
    expect(controller.loading, isFalse);
    controller.dispose();
    await repository.identities.close();
  });

  testWidgets('second range page permission loss clears all displayed pages', (
    tester,
  ) async {
    final now = tester.binding.clock.now().toUtc();
    final first = _request('first', now);
    final older = _request('older', now.subtract(const Duration(hours: 1)));
    var forbidden = false;
    final repository = CommunityRepo()
      ..feeding = (cursor) async {
        if (cursor != null && forbidden) {
          throw const CommunityException('membership_required');
        }
        return CommunityPage(
          cursor == null ? [first] : [older],
          cursor == null ? {'id': 'second'} : null,
          now,
        );
      };
    final controller = CommunityController(
      repository,
      drafts: Drafts(),
      now: () => now,
    );
    await controller.refresh();
    await controller.loadMore();
    forbidden = true;
    await controller.refresh();
    expect(controller.requests, isEmpty);
    expect(controller.hasMore, isFalse);
    expect(controller.error, isNotNull);
    controller.dispose();
    await repository.identities.close();
  });

  testWidgets(
    'late range response after disposal cannot notify or schedule expiry',
    (tester) async {
      final now = tester.binding.clock.now().toUtc();
      final gate = Completer<CommunityPage>();
      final repository = CommunityRepo()..feeding = (_) => gate.future;
      final controller = CommunityController(
        repository,
        drafts: Drafts(),
        now: () => tester.binding.clock.now(),
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final refreshing = controller.refresh();
      controller.dispose();
      final before = notifications;
      gate.complete(
        CommunityPage(
          [_request('late', now, expires: now.add(const Duration(seconds: 1)))],
          null,
          now,
        ),
      );
      await refreshing;
      await tester.pump(const Duration(seconds: 2));
      expect(notifications, before);
      expect(controller.requests, isEmpty);
      expect(tester.takeException(), isNull);
      await repository.identities.close();
    },
  );
  testWidgets(
    '30 day expiry uses browser-safe timers and retains its full lifetime',
    (tester) async {
      final clock = tester.binding.clock;
      final start = clock.now().toUtc();
      final repository = CommunityRepo()
        ..feeding = (_) async => CommunityPage(
          [_request('long-lived', start)],
          null,
          clock.now().toUtc(),
        );
      final controller = CommunityController(
        repository,
        drafts: Drafts(),
        now: clock.now,
      );
      final delays = <Duration>[];
      await runZoned(
        controller.refresh,
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, delay, callback) {
            delays.add(delay);
            return parent.createTimer(zone, delay, callback);
          },
        ),
      );
      expect(delays, contains(const Duration(days: 1)));
      expect(delays.every((delay) => delay <= const Duration(days: 1)), isTrue);
      await tester.pump(const Duration(days: 29));
      expect(controller.requests.single.id, 'long-lived');
      await tester.pump(const Duration(days: 1));
      expect(controller.requests, isEmpty);
      controller.dispose();
      await repository.identities.close();
    },
  );
}
