import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'native_session_storage.dart';
import 'sqlite_journal_store.dart';

Future<void> initializePlatformStorage() async {
  if (!Platform.isIOS && !Platform.isAndroid) return;
  if (NativeSessionStorage.installed != null) return;
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  final database = SqliteJournalStore.open(
    '${directory.path}/paul-operations.sqlite',
  );
  NativeSessionStorage.install(database, scope: 'installation');
}
