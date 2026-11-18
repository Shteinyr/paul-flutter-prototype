import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/community/community_controller.dart';
import 'package:paul_demo/community/community_views.dart';
import 'package:paul_demo/live/continue_setup_dialog.dart';

import 'community_controller_test.dart';
import 'live_chat_controller_test.dart' show Drafts;

class _SlowDetailRepo extends CommunityRepo {
  int gets = 0;
  Future<CommunityRequest?> Function()? getting;
  @override
  Future<CommunityRequest?> get(String id) async {
    gets++;
    return getting == null ? item : getting!();
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  testWidgets('level nine opens P15 only on a blocked publish action', (
    tester,
  ) async {
    final repo = CommunityRepo()..invitations = 9;
    final controller = CommunityController(repo, drafts: Drafts());
    var invites = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityComposeView(
          controller: controller,
          onInvite: () {},
          onPublishLimit: () async {
            if (await showContinueSetupDialog(
                  tester.element(find.byType(CommunityComposeView)),
                  invitedRegistrations: 9,
                ) ==
                true) {
              invites++;
            }
          },
          initialSkill: 'Marketing',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Continue setup'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('community-skill')))
          .enabled,
      isTrue,
    );
    await tester.enterText(
      find.byKey(const Key('community-message')),
      'My request',
    );
    await tester.ensureVisible(find.byKey(const Key('community-publish')));
    await tester.tap(find.byKey(const Key('community-publish')));
    await tester.pumpAndSettle();
    expect(find.text('Continue setup'), findsOneWidget);
    expect(find.text('2 of 3'), findsOneWidget);
    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    expect(invites, 1);
    repo.invitations = 10;
    await controller.refreshCapabilities();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('community-skill')))
          .enabled,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await repo.identities.close();
  });

  testWidgets(
    'free text publishes, lost response retains text for same-op retry',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repo = CommunityRepo();
      final controller = CommunityController(repo, drafts: Drafts());
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CommunityComposeView(
                    controller: controller,
                    onInvite: () {},
                    initialSkill: 'Custom skill',
                  ),
                ),
              ),
              child: const Text('Open compose'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open compose'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('community-message')),
        'A free-text request',
      );
      repo.creating = () =>
          Future.error(const CommunityException('server_unavailable'));
      await tester.ensureVisible(find.byKey(const Key('community-publish')));
      await tester.tap(find.byKey(const Key('community-publish')));
      await tester.pumpAndSettle();
      expect(find.text('Retry submission'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('community-message')))
            .enabled,
        isFalse,
      );
      final original = repo.creates.single;
      repo.creating = null;
      await tester.ensureVisible(find.byKey(const Key('community-publish')));
      await tester.tap(find.byKey(const Key('community-publish')));
      await tester.pumpAndSettle();
      expect(find.text('Open compose'), findsOneWidget);
      expect(repo.creates.last, original);
      expect(repo.creates.last.$2, 'Custom skill');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await repo.identities.close();
    },
  );

  testWidgets('feed keeps older active requests without an invented heading', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    final sample = request();
    final repo = CommunityRepo()
      ..feeding = (_) async => CommunityPage(
        [
          for (final days in [0, 6, 7, 20])
            CommunityRequest(
              id: 'age-$days',
              author: sample.author,
              skill: sample.skill,
              message: sample.message,
              createdAt: now.subtract(Duration(days: days)),
              expiresAt: now.add(const Duration(days: 1)),
              isAuthor: false,
            ),
        ],
        null,
        now,
      );
    final controller = CommunityController(repo, drafts: Drafts());
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityFeedView(
          controller: controller,
          onInvite: () {},
          onMessage: (_, _) async {},
          avatarFor: (_) => const CircleAvatar(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Last week'), findsOneWidget);
    expect(find.text('Earlier'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('community-age-20')),
      200,
    );
    expect(find.byKey(const ValueKey('community-age-20')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await repo.identities.close();
  });

  for (final skill in ['Sales Representative', 'Photographer', 'x' * 64]) {
    testWidgets('Hiring keeps narrow skill text readable: $skill', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 245,
                child: HiringRequestRow(
                  name: 'Alex Morgan',
                  skill: skill,
                  avatar: const SizedBox.square(dimension: 65),
                ),
              ),
            ),
          ),
        ),
      );
      const prefix = 'Urgent Hiring:  ';
      final text = find.text('$prefix$skill');
      expect(text, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      );
      if (skill.length < 64) {
        var offset = prefix.length;
        for (final word in skill.split(' ')) {
          expect(
            paragraph.getBoxesForSelection(
              TextSelection(
                baseOffset: offset,
                extentOffset: offset + word.length,
              ),
            ),
            hasLength(1),
            reason: '$word should stay on one line at 320 pixels',
          );
          offset += word.length + 1;
        }
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'feed detail re-reads request before message and handles expiry',
    (tester) async {
      final repo = CommunityRepo();
      final controller = CommunityController(repo, drafts: Drafts());
      final peers = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CommunityFeedView(
            controller: controller,
            onInvite: () {},
            onMessage: (_, peer) async => peers.add(peer.id),
            avatarFor: (_) => const CircleAvatar(child: Text('A')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Urgent Hiring:  Marketing'), findsOneWidget);
      expect(find.text('Earlier'), findsNothing);
      expect(
        find.widgetWithText(FilledButton, 'Ask our community'),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('community-$requestId')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Message author'));
      await tester.pumpAndSettle();
      expect(peers, ['b']);
      repo.item = null;
      await tester.tap(find.text('Message author'));
      await tester.pumpAndSettle();
      expect(peers, ['b']);
      expect(find.text('This request is no longer available.'), findsOneWidget);
      expect(find.text('Message author'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await repo.identities.close();
    },
  );

  testWidgets('owner confirms close and unavailable replaces request', (
    tester,
  ) async {
    final repo = CommunityRepo()..item = request(own: true);
    final controller = CommunityController(repo, drafts: Drafts());
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityDetailView(
          controller: controller,
          requestId: requestId,
          onMessage: (_, _) async {},
          avatarFor: (_) => const CircleAvatar(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Message author'), findsNothing);
    await tester.tap(find.text('Close request'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.closes, isEmpty);
    await tester.tap(find.text('Close request'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Close request'));
    await tester.pumpAndSettle();
    expect(repo.closes.single.$2, requestId);
    expect(find.text('This request is no longer available.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await repo.identities.close();
  });

  testWidgets(
    'detail coalesces refresh, retries failures and hides lost identity',
    (tester) async {
      final repo = _SlowDetailRepo();
      final gate = Completer<CommunityRequest?>();
      repo.getting = () => gate.future;
      final controller = CommunityController(repo, drafts: Drafts());
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: CommunityDetailView(
              controller: controller,
              requestId: requestId,
              onMessage: (_, _) async {},
              avatarFor: (_) => const CircleAvatar(),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Refresh request'));
        await tester.pump();
        expect(repo.gets, 1);
        gate.completeError(const CommunityException('server_unavailable'));
        await tester.pumpAndSettle();
        expect(find.text('Retry'), findsOneWidget);
        repo.getting = () async => request();
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(repo.gets, 2);
        expect(find.text('Help with a launch'), findsOneWidget);
        expect(find.text('Message author'), findsOneWidget);
        expect(find.text('Close request'), findsNothing);
        repo.currentUserId = null;
        repo.identities.add(null);
        await tester.pumpAndSettle();
        expect(find.text('Help with a launch'), findsNothing);
        expect(find.text('Message author'), findsNothing);
        expect(find.text('Please sign in again to continue.'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete(null);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await repo.identities.close();
      }
    },
  );

  testWidgets(
    'pending detail refresh cannot reopen a closed or expired request',
    (tester) async {
      final repo = _SlowDetailRepo()..item = request(own: true);
      final controller = CommunityController(repo, drafts: Drafts());
      final gate = Completer<CommunityRequest?>();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: CommunityDetailView(
              controller: controller,
              requestId: requestId,
              onMessage: (_, _) async {},
              avatarFor: (_) => const CircleAvatar(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        repo.getting = () => gate.future;
        await tester.tap(find.byTooltip('Refresh request'));
        await tester.pump();
        await tester.tap(find.text('Close request'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(TextButton, 'Close request'));
        await tester.pumpAndSettle();
        gate.complete(request(own: true));
        await tester.pumpAndSettle();
        expect(
          find.text('This request is no longer available.'),
          findsOneWidget,
        );
        expect(find.text('Help with a launch'), findsNothing);
        expect(find.text('Close request'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        if (!gate.isCompleted) gate.complete(null);
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await repo.identities.close();
      }
    },
  );
}
