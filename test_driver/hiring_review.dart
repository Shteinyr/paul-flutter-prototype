// Private local acceptance entrypoint. Never use this target for delivery.
// Build with --dart-define-from-file pointing to an ignored local QA config.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:paul_demo/account/deletion.dart';
import 'package:paul_demo/config/app_configuration.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/platform/storage/native_session_storage.dart';
import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('PAUL_QA_HIRING');
  const url = String.fromEnvironment('PAUL_QA_URL');
  const key = String.fromEnvironment('PAUL_QA_PUBLISHABLE_KEY');
  const refreshToken = String.fromEnvironment('PAUL_QA_REFRESH_TOKEN');
  final uri = Uri.tryParse(url);
  // Validate before opening storage or constructing an authenticated client.
  // No hosted fallback, release target, or web session is permitted here.
  if (!kDebugMode ||
      kIsWeb ||
      !enabled ||
      !(Platform.isIOS || Platform.isAndroid) ||
      uri == null ||
      uri.scheme != 'http' ||
      !const {'127.0.0.1', 'localhost', '10.0.2.2'}.contains(uri.host) ||
      uri.port != 55431 ||
      uri.userInfo.isNotEmpty ||
      !(uri.path.isEmpty || uri.path == '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      key.isEmpty ||
      refreshToken.isEmpty) {
    _unavailable();
    return;
  }

  SupabaseClient? client;
  try {
    // Fulfil the native storage bootstrap contract with a separate journal.
    // Normal installation drafts and operation receipts stay untouched.
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    NativeSessionStorage.install(
      SqliteJournalStore.open('${directory.path}/paul-hiring-review.sqlite'),
      scope: 'qa:hiring17:installation',
    );
    // A plain client keeps Auth in memory. Do not call Supabase.initialize:
    // its Flutter persistence would share the normal app's saved login.
    client = SupabaseClient(url, key);
    final preferences = _ReviewPreferences();
    final savedRefresh = await preferences.getString('auth.refresh');
    // Refresh tokens rotate. Persist only this local QA session under its own
    // prefix so an ordinary second launch remains usable after the reuse window.
    client.auth.onAuthStateChange.listen((event) {
      final refresh = event.session?.refreshToken;
      if (refresh != null) {
        preferences.setString('auth.refresh', refresh).ignore();
      }
    });
    await client.auth.setSession(savedRefresh ?? refreshToken);
    if (client.auth.currentSession == null) {
      throw StateError('Local QA session unavailable');
    }
    await preferences.setString(
      'auth.refresh',
      client.auth.currentSession!.refreshToken!,
    );
    runApp(
      PaulLiveApp(
        client: client,
        appUrl: uri,
        purpose: AppPurpose.app,
        draftPreferences: preferences,
        deletionStore: PreferenceDeletionStore(preferences),
        platformPushFactory: (_) async => null,
      ),
    );
  } catch (_) {
    await client?.dispose();
    // Auth errors may contain private details; never render or log them.
    _unavailable();
  }
}

// Keep QA onboarding and deletion recovery away from the normal app's keys.
// All repositories still use the real local handlers.
class _ReviewPreferences extends SharedPreferencesAsync {
  static const _prefix = 'paul.qa.hiring17.';

  @override
  Future<String?> getString(String key) => super.getString('$_prefix$key');

  @override
  Future<void> setString(String key, String value) =>
      super.setString('$_prefix$key', value);

  @override
  Future<void> remove(String key) => super.remove('$_prefix$key');

  @override
  Future<Set<String>> getKeys({Set<String>? allowList}) async => {
    for (final key in await super.getKeys())
      if (key.startsWith(_prefix) &&
          (allowList == null ||
              allowList.contains(key.substring(_prefix.length))))
        key.substring(_prefix.length),
  };
}

void _unavailable() => runApp(
  const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      body: Center(child: Text('Local Hiring review is unavailable.')),
    ),
  ),
);
