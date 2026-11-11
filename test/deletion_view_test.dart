import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/account/deletion.dart';
import 'package:paul_demo/account/deletion_view.dart';

import 'deletion_controller_test.dart';

void main() {
  testWidgets(
    'permanent deletion requires explicit confirmation and supports cancellation',
    (tester) async {
      bool? confirmed;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  confirmed = await confirmProfileDeletion(context),
              child: const Text('Delete account'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Deleted user'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);
      await tester.tap(find.text('Delete account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    },
  );

  testWidgets(
    'pending deletion survives sign-out and reaches complete through status',
    (tester) async {
      final repo = DeletionRepo();
      final store = MemoryDeletionStore();
      final controller = DeletionController(repo, store);
      final record = (await controller.begin(actor))!;
      expect(repo.currentUserId, isNull);
      var dismissed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: DeletionStatusView(
            controller: controller,
            record: record,
            onDone: () => dismissed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Profile removed. Finishing account and photo cleanup…'),
        findsOneWidget,
      );
      expect(find.text('Account deleted'), findsNothing);
      repo.done = true;
      await tester.tap(find.text('Check deletion status'));
      await tester.pumpAndSettle();
      expect(find.text('Account deleted'), findsOneWidget);
      await tester.tap(find.text('Done'));
      expect(dismissed, isTrue);
      expect(controller.records, isEmpty);
      expect(store.saved, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );
}
