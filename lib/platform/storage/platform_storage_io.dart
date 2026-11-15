import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'native_session_storage.dart';
import 'sqlite_journal_store.dart';
import 'sqlite_adapters.dart';
import '../../live/chat_controller.dart';

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

ChatStateStore createChatStateStore(String accountId) =>
    Platform.isIOS || Platform.isAndroid
    ? SqliteChatStateStore(
        NativeSessionStorage.current.database,
        accountId: accountId,
      )
    : SessionChatStateStore();

void deleteAccountStorage(String accountId) {
  if (!Platform.isIOS &&
      !Platform.isAndroid &&
      NativeSessionStorage.installed == null) {
    return;
  }
  NativeSessionStorage.current.database.deleteAccountData(accountId);
}
