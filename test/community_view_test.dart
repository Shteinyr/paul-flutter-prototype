import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/community/community_controller.dart';
import 'package:paul_demo/community/community_views.dart';

import 'community_controller_test.dart';
import 'live_chat_controller_test.dart' show Drafts;

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  testWidgets('level nine shows invitations and blocks publishing', (
    tester,
  ) async {
    final repo = CommunityRepo()..invitations = 9;
    final controller = CommunityController(repo, drafts: Drafts());
    var invites = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CommunityComposeView(
          controller: controller,
          onInvite: () => invites++,
          initialSkill: 'Marketing',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('9 joined with your invitation'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('community-skill')))
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Invite friends'));
    expect(invites, 1);
    repo.invitations = 10;
    await tester.tap(find.text('Refresh invitation level'));
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
      expect(find.text('Urgent Hiring:  '), findsOneWidget);
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
}
