import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/invitation_controller.dart';

class _Issuer implements InvitationIssuer {
  final tokens = <String>[];
  final revoked = <String>[];
  Object? failure;
  Completer<LiveInvitation>? pending;

  @override
  Future<LiveInvitation> issue(String token) async {
    tokens.add(token);
    final error = failure;
    failure = null;
    if (error != null) throw error;
    if (pending != null) return pending!.future;
    return LiveInvitation(
      id: 'invite-${tokens.length}',
      token: token,
      code: tokens.length.toString().padLeft(8, '0'),
      expiresAt: DateTime.utc(2030),
      lifetime: const Duration(minutes: 15),
    );
  }

  @override
  Future<void> revoke(String id) async => revoked.add(id);
}

void main() {
  testWidgets(
    'open QR automatically rotates token and code at the server lifetime',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed)
        ..start();
      await tester.pump();
      final original = controller.invitation!;
      expect(controller.remaining, const Duration(minutes: 15));
      elapsed = const Duration(minutes: 14, seconds: 59);
      await tester.pump(const Duration(seconds: 1));
      expect(issuer.tokens, hasLength(1));
      expect(controller.remaining, const Duration(seconds: 1));
      elapsed = const Duration(minutes: 15);
      await tester.pump(const Duration(seconds: 1));
      expect(issuer.tokens, hasLength(2));
      expect(controller.invitation!.token, isNot(original.token));
      expect(controller.invitation!.code, isNot(original.code));
      expect(controller.remaining, const Duration(minutes: 15));
      controller.dispose();
    },
  );

  testWidgets(
    'expiry hides old credentials when renewal fails and retry is idempotent',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed)
        ..start();
      await tester.pump();
      issuer.failure = StateError('Offline');
      elapsed = const Duration(minutes: 15);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.usable, false);
      expect(controller.invitation, null);
      expect(controller.error, isNotNull);
      final retryToken = issuer.tokens.last;
      await controller.refresh();
      expect(issuer.tokens.last, retryToken);
      expect(controller.usable, true);
      controller.dispose();
    },
  );

  testWidgets(
    'expired issuance retry receives a fresh token instead of reviving the old one',
    (tester) async {
      final issuer = _Issuer()..failure = InvitationRenewalRequired();
      final controller = InvitationController(issuer)..start();
      await tester.pump();
      final expired = issuer.tokens.single;
      await controller.refresh();
      expect(issuer.tokens.last, isNot(expired));
      controller.dispose();
    },
  );

  testWidgets(
    'background pauses issuance and returning checks expiry immediately',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed)
        ..start();
      await tester.pump();
      controller.pause();
      elapsed = const Duration(minutes: 16);
      await tester.pump(const Duration(minutes: 16));
      expect(issuer.tokens, hasLength(1));
      expect(controller.usable, false);
      controller.start();
      await tester.pump();
      expect(issuer.tokens, hasLength(2));
      controller.dispose();
    },
  );

  testWidgets(
    'duplicate renew clicks and late responses after disposal cannot mutate the screen',
    (tester) async {
      final issuer = _Issuer()..pending = Completer<LiveInvitation>();
      final controller = InvitationController(issuer)..start();
      await controller.refresh();
      expect(issuer.tokens, hasLength(1));
      controller.dispose();
      issuer.pending!.complete(
        LiveInvitation(
          id: 'late',
          token: issuer.tokens.single,
          code: '12345678',
          expiresAt: DateTime.utc(2030),
          lifetime: const Duration(minutes: 15),
        ),
      );
      await tester.pump();
      expect(controller.invitation, null);
      expect(tester.takeException(), null);
    },
  );

  testWidgets(
    'owner revocation generates a replacement while screen remains open',
    (tester) async {
      final issuer = _Issuer();
      final controller = InvitationController(issuer)..start();
      await tester.pump();
      final id = controller.invitation!.id;
      await controller.revoke();
      expect(issuer.revoked, [id]);
      expect(issuer.tokens, hasLength(2));
      expect(controller.usable, true);
      controller.dispose();
    },
  );
}
