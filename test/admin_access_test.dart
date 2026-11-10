import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/admin/admin_view.dart';

class _AdminRepository implements AdminRepository {
  Future<AdminAccess> Function() load = () async =>
      const AdminAccess('admin', []);
  @override
  Future<AdminAccess> context() => load();
}

void main() {
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
}
