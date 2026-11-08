import 'package:flutter/material.dart';

import 'app.dart';
import 'chat/demo_chat_controller.dart';
import 'profile/profile_controller.dart';
import 'profile/demo_profile.dart';
import 'profile/profile_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
