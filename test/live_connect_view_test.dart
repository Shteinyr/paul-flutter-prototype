import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/invitation_actions.dart';
import 'package:paul_demo/live/invitation_controller.dart';
import 'package:paul_demo/live/live_connect_view.dart';

class _Issuer implements InvitationIssuer {
  int issued = 0;
  bool failing = false;

  @override
  Future<LiveInvitation> issue(String token) async {
    if (failing) throw StateError('offline');
    issued++;
    return LiveInvitation(
      id: '$issued',
      token: token,
      code: 'code-$issued',
      expiresAt: DateTime.utc(2030),
      lifetime: const Duration(minutes: 15),
    );
  }

  @override
  Future<void> revoke(String id) async {}
}

class _Actions implements InvitationActions {
  @override
  bool canShare = true;
  final copies = <String>[];
  final shares = <String>[];
  InvitationActionResult result = InvitationActionResult.completed;
  Completer<InvitationActionResult>? pending;

  @override
  Future<InvitationActionResult> copy(String message) {
    copies.add(message);
    return pending?.future ?? Future.value(result);
  }

  @override
  Future<InvitationActionResult> share(String message) {
    shares.add(message);
    return pending?.future ?? Future.value(result);
  }
}

Future<void> _open(
  WidgetTester tester,
  InvitationController controller,
  _Actions actions,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LiveConnectView(
        invitation: controller,
        appUrl: Uri.parse('https://paul.example/'),
        actions: actions,
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Share'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'copy confirms completion and native share receives current credentials',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      await tester.tap(find.byKey(const Key('copy-live-invitation')));
      await tester.pumpAndSettle();
      expect(find.text('Invitation copied.'), findsOneWidget);
      expect(
        actions.copies.single,
        contains(
          'https://paul.example/#invite=${controller.invitation!.token}',
        ),
      );
      expect(actions.copies.single, contains('code-1'));
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      expect(actions.shares, hasLength(1));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Confirm delivery in the receiving app.'),
        findsOneWidget,
      );
      controller.dispose();
    },
  );

  testWidgets('copy failure and retry preserve manual text', (tester) async {
    final controller = InvitationController(_Issuer());
    await controller.refresh();
    final actions = _Actions()..result = InvitationActionResult.denied;
    await _open(tester, controller, actions);
    await tester.tap(find.byKey(const Key('copy-live-invitation')));
    await tester.pumpAndSettle();
    expect(find.textContaining('browser blocked'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    actions.result = InvitationActionResult.completed;
    await tester.tap(find.byKey(const Key('copy-live-invitation')));
    await tester.pumpAndSettle();
    expect(find.text('Invitation copied.'), findsOneWidget);
    expect(actions.copies, hasLength(2));
    controller.dispose();
  });

  testWidgets('unsupported browser and cancellation retain copy path', (
    tester,
  ) async {
    final controller = InvitationController(_Issuer());
    await controller.refresh();
    final actions = _Actions()..canShare = false;
    await _open(tester, controller, actions);
    expect(find.byKey(const Key('share-live-invitation')), findsNothing);
    expect(
      find.textContaining('System sharing is unavailable'),
      findsOneWidget,
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    actions.canShare = true;
    actions.result = InvitationActionResult.cancelled;
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-live-invitation')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sharing cancelled.'), findsOneWidget);
    expect(find.byKey(const Key('copy-live-invitation')), findsOneWidget);
    controller.dispose();
  });

  testWidgets(
    'pending action blocks repeats and ignores completion after close',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final actions = _Actions()..pending = Completer();
      await _open(tester, controller, actions);
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      expect(actions.shares, hasLength(1));
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      actions.pending!.complete(InvitationActionResult.completed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Connect'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets(
    'open preview follows renewal and stale share requires fresh tap',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed);
      await controller.refresh();
      final actions = _Actions()..pending = Completer();
      await _open(tester, controller, actions);
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      await tester.pump();
      elapsed = const Duration(minutes: 15);
      actions.pending!.complete(InvitationActionResult.completed);
      await tester.pumpAndSettle();
      expect(issuer.issued, 2);
      expect(find.textContaining('Use invite code: code-2'), findsWidgets);
      expect(find.textContaining('invitation changed'), findsOneWidget);
      expect(actions.shares, hasLength(1));
      expect(find.textContaining('Share request completed'), findsNothing);
      actions.pending = null;
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      await tester.pumpAndSettle();
      expect(actions.shares.last, contains('code-2'));
      controller.dispose();
    },
  );

  testWidgets(
    'renewal failure hides old credentials and allows explicit retry',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed);
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      elapsed = const Duration(minutes: 15);
      issuer.failing = true;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Retry invitation'), findsOneWidget);
      issuer.failing = false;
      await tester.tap(find.text('Retry invitation'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use invite code: code-2'), findsWidgets);
      expect(actions.shares, isEmpty);
      controller.dispose();
    },
  );
}
