import 'dart:io';

import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';

Future<void> main(List<String> arguments) async {
  const actor = '15000000-0000-4000-8000-000000000001';
  final store = SqliteJournalStore.open(arguments.single);
  store.write('account:$actor', 'process-proof', 'durable');
  store.prepare(
    JournalOperation(
      scope: 'account:$actor',
      kind: 'profile',
      target: actor,
      operationId: '15000000-0000-4000-8000-000000000003',
      payload: const {'name': 'pending'},
    ),
  );
  stdout.writeln('committed');
  await stdout.flush();
  // The parent kills this process. No SQLite close/checkpoint runs here.
  await stdin.drain<void>();
}
