import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/admin/admin_view.dart';
import 'package:paul_demo/live/chat_api.dart';

const _profiles = [
  ManagedProfile(
    id: 'managed-a',
    name: 'Managed A',
    canManage: true,
    canReply: true,
    summary: 'First profile',
    skills: ['Design'],
  ),
  ManagedProfile(
    id: 'managed-b',
    name: 'Managed B',
    canManage: true,
    canReply: true,
    summary: 'Second profile',
    skills: ['Marketing'],
  ),
];

class _Chat extends Fake implements ChatRepository {
  @override
  String? get currentUserId => 'qa-admin';
  @override
  Stream<String?> get identityChanges => const Stream.empty();
  @override
  Stream<String> watch() => const Stream.empty();
  @override
  Future<List<ChatSummary>> list() async => [];
}

class _Admin extends Fake implements AdminRepository {
  @override
  String get userId => 'qa-admin';
  final opened = <String>[];
  List<ManagedProfile> profiles = _profiles;
  Completer<AdminAccess>? pending;
  int reads = 0;
  @override
  Future<AdminAccess> context() async {
    reads++;
    return pending == null ? AdminAccess('admin', profiles) : pending!.future;
  }

  @override
  Future<Uint8List?> photo(ManagedProfile profile) async => null;
  @override
  ChatRepository operatorFor(String profileId) {
    opened.add(profileId);
    return _Chat();
  }
}

Widget _app(_Admin admin) => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => AdminView(repository: admin)),
        ),
        child: const Text('My profile'),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'selected workspace switches the sender and edits the selected profile',
    (tester) async {
      final admin = _Admin();
      await tester.pumpWidget(_app(admin));
      await tester.tap(find.text('My profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Managed A'));
      await tester.pumpAndSettle();
      expect(admin.opened, ['managed-a']);
      expect(find.byKey(const Key('managed-profile-switcher')), findsOneWidget);
      await tester.tap(find.byKey(const Key('managed-profile-switcher')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Managed B').last);
      await tester.pumpAndSettle();
      expect(admin.opened, ['managed-a', 'managed-b']);
      expect(admin.userId, 'qa-admin');
      await tester.tap(find.text('Edit profile'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('name-field')))
            .controller!
            .text,
        'Managed B',
      );
      admin.profiles = [_profiles.first];
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(
        find.text('Administrative access is unavailable for this account.'),
        findsOneWidget,
      );
      expect(find.text('Edit profile'), findsNothing);
      await tester.tap(find.byTooltip('Return to my profile'));
      await tester.pumpAndSettle();
      expect(find.text('My profile'), findsOneWidget);
      expect(admin.reads, greaterThanOrEqualTo(4));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('switch waits for fresh access and hides the previous context', (
    tester,
  ) async {
    final admin = _Admin();
    await tester.pumpWidget(_app(admin));
    await tester.tap(find.text('My profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Managed A'));
    await tester.pumpAndSettle();
    final pending = Completer<AdminAccess>();
    admin.pending = pending;
    await tester.tap(find.byKey(const Key('managed-profile-switcher')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Managed B').last);
    await tester.pump();
    expect(find.byKey(const Key('managed-profile-switcher')), findsNothing);
    expect(find.text('Edit profile'), findsNothing);
    pending.completeError(const AdminException('admin_forbidden'));
    await tester.pumpAndSettle();
    expect(admin.opened, ['managed-a']);
    expect(
      find.text('Administrative access is unavailable for this account.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
