import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/live_qr_view.dart';
import 'package:paul_demo/live/invitation_controller.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'profile_controller_test.dart' show MemoryProfileStore;

class _SourceIssuer implements InvitationIssuer {
  final revoked = <String>[];
  @override
  Future<LiveInvitation> issue(String token) async => LiveInvitation(
    id: 'source-invite',
    token: token,
    code: '12345678',
    expiresAt: DateTime.now().add(const Duration(minutes: 15)),
    lifetime: const Duration(minutes: 15),
  );
  @override
  Future<void> revoke(String id) async {
    revoked.add(id);
  }
}

void main() {
  testWidgets(
    'P04 shows the live QR/code without developer countdown or revoke controls',
    (tester) async {
      final store = MemoryProfileStore()
        ..saved = const UserProfile(
          name: 'Julia Robinson',
          occupation: 'UI/UX Designer',
        ).encode();
      final profile = ProfileController(store);
      await profile.load();
      final issuer = _SourceIssuer();
      await tester.pumpWidget(
        MaterialApp(
          home: LiveQrView(
            profile: profile,
            issuer: issuer,
            appUrl: Uri.parse('https://paul.example'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-qr-image')), findsOneWidget);
      expect(find.text('12345678'), findsOneWidget);
      expect(find.textContaining('New QR in'), findsNothing);
      expect(find.text('Revoke and generate new'), findsNothing);
      expect(issuer.revoked, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      profile.dispose();
    },
  );
}
