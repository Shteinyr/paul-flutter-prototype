import 'package:flutter/material.dart';

import 'app.dart';
import 'config/app_configuration.dart';
import 'chat/demo_chat_controller.dart';
import 'profile/profile_controller.dart';
import 'profile/demo_profile.dart';
import 'profile/profile_store.dart';
import 'live/live_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final configuration = AppConfiguration.environment();
  if (configuration.purpose != AppPurpose.demo) {
    runApp(
      await buildLiveApp(
        url: configuration.url,
        key: configuration.key,
        appUrl: configuration.appUrl,
        purpose: configuration.purpose,
      ),
    );
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
