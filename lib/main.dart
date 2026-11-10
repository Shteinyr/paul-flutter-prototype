import 'package:flutter/material.dart';

import 'app.dart';
import 'chat/demo_chat_controller.dart';
import 'profile/profile_controller.dart';
import 'profile/demo_profile.dart';
import 'profile/profile_store.dart';
import 'live/live_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('PAUL_LIVE')) {
    const url = String.fromEnvironment('SUPABASE_URL');
    const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const appUrl = String.fromEnvironment('PAUL_APP_URL');
    runApp(await buildLiveApp(url: url, key: key, appUrl: appUrl));
    return;
  }
  final controller = ProfileController(
    PreferencesProfileStore(
      seedProfile: loadDemoProfile,
      migrateProfile: migrateDemoProfile,
    ),
  );
  await controller.load();
  final chat = DemoChatController(store: PreferencesDemoChatStore());
  await chat.load();
  runApp(PaulDemoApp(controller: controller, chatController: chat));
}
