import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/chat_controller.dart';
import 'package:paul_demo/admin/operator_inbox_view.dart';
import 'package:paul_demo/admin/admin_view.dart';
import 'package:paul_demo/admin/managed_profile_editor.dart';

class _AdminRepository implements AdminRepository {
  @override
  String get userId => 'admin-qa';
  @override
  ChatRepository operatorFor(String profileId) => throw UnimplementedError();
  Future<AdminAccess> Function() load = () async =>
      const AdminAccess('admin', []);
  @override
  Future<AdminAccess> context() => load();
  @override
  Future<Uint8List?> photo(ManagedProfile profile) async => null;
  final commands = <String>[];
  bool failSave = false;
  @override
  Future<void> command(Map<String, dynamic> fields) async {
    commands.add(jsonEncode(fields));
    if (failSave) throw TimeoutException('Lost response');
  }
}

void main() {
  test(
    'operator journal is separately scoped by Auth actor and managed sender',
    () async {
      final first = OperatorChatStateStore('managed-first');
      final second = OperatorChatStateStore('managed-second');
      final normal = SessionChatStateStore();
      await first.write('operator-a', 'First');
      await second.write('operator-a', 'Second');
      await first.write('operator-b', 'Other actor');
      await normal.write('operator-a', 'Personal');
      expect(await first.read('operator-a'), 'First');
      expect(await second.read('operator-a'), 'Second');
      expect(await first.read('operator-b'), 'Other actor');
      expect(await normal.read('operator-a'), 'Personal');
    },
  );

  testWidgets('ordinary member never sees Admin entry', (tester) async {
    final repository = _AdminRepository()
      ..load = () async => throw const AdminException('admin_forbidden');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminEntry(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Admin'), findsNothing);
    expect(find.text('No assigned profiles.'), findsNothing);
  });

  testWidgets('Admin rechecks role at entry and blocks revoked access', (
    tester,
  ) async {
    final repository = _AdminRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AdminEntry(repository: repository)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin-entry')), findsOneWidget);
    repository.load = () async => throw const AdminException('admin_forbidden');
    await tester.tap(find.byKey(const Key('admin-entry')));
    await tester.pumpAndSettle();
    expect(
      find.text('Administrative access is unavailable for this account.'),
      findsOneWidget,
    );
    expect(find.text('User management'), findsNothing);
  });

  testWidgets(
    'refresh hides previously loaded private profiles while pending or denied',
    (tester) async {
      final repository = _AdminRepository()
        ..load = () async => const AdminAccess('admin', [
          ManagedProfile(
            id: 'managed-qa',
            name: 'Assigned QA',
            canManage: true,
            canReply: false,
          ),
        ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AdminView(repository: repository)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Assigned QA'), findsOneWidget);
      final pending = Completer<AdminAccess>();
      repository.load = () => pending.future;
      final refresh = tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await tester.pump();
      expect(find.text('Assigned QA'), findsNothing);
      pending.completeError(const AdminException('admin_forbidden'));
      await refresh;
      await tester.pumpAndSettle();
      expect(find.text('Assigned QA'), findsNothing);
      expect(
        find.text('Administrative access is unavailable for this account.'),
        findsOneWidget,
      );
    },
  );
  testWidgets(
    'managed draft cancel writes nothing and failed Save retries the original operation',
    (tester) async {
      final repository = _AdminRepository();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ManagedProfileEditor(
                      repository: repository,
                      profile: const ManagedProfile(
                        id: 'managed-qa',
                        name: 'Managed QA',
                        canManage: true,
                        canReply: true,
                        summary: 'QA summary',
                        skills: ['Design'],
                        updatedAt: '2026-11-10T00:00:00Z',
                      ),
                    ),
                  ),
                ),
                child: const Text('Open editor'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      expect(repository.commands, isEmpty);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(repository.commands, isEmpty);
      await tester.tap(find.text('Open editor'));
      await tester.pumpAndSettle();
      repository.failSave = true;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(repository.commands, hasLength(1));
      expect(find.text('Retry save'), findsOneWidget);
      repository.failSave = false;
      await tester.tap(find.text('Retry save'));
      await tester.pumpAndSettle();
      expect(repository.commands, hasLength(2));
      expect(repository.commands[0], repository.commands[1]);
      expect(find.text('Open editor'), findsOneWidget);
    },
  );
}
