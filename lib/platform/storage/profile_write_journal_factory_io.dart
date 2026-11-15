import 'dart:io';

import 'native_session_storage.dart';
import 'profile_write_journal.dart';
import 'profile_write_journal_memory.dart';
import 'sqlite_adapters.dart';

ProfileWriteJournal createProfileWriteJournal() =>
    Platform.isIOS || Platform.isAndroid
    ? SqliteProfileWriteJournal(NativeSessionStorage.current.database)
    : MemoryProfileWriteJournal();
