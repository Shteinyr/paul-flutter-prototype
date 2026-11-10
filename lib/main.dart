import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app.dart';
import 'chat/demo_chat_controller.dart';
import 'profile/profile_controller.dart';
import 'profile/demo_profile.dart';
import 'profile/profile_store.dart';
import 'live/live_app.dart';
import 'live/guest_preview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('PAUL_LIVE')) {
    const url = String.fromEnvironment('SUPABASE_URL');
    const key = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
    const appUrl = String.fromEnvironment('PAUL_APP_URL');
    final authCallback = Uri.base.queryParameters['auth'] == 'callback';
    try {
      if (url.isEmpty || key.isEmpty || appUrl.isEmpty) {
        throw const FormatException('Missing live configuration');
      }
      await Supabase.initialize(
        url: url,
        publishableKey: key,
        debug: false,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
      runApp(
        PaulLiveApp(
          client: Supabase.instance.client,
          appUrl: Uri.parse(appUrl),
          authCallback: authCallback,
          loadAuthProviders: () async {
            final response = await http
                .get(
                  Uri.parse('$url/auth/v1/settings'),
                  headers: {'apikey': key},
                )
                .timeout(const Duration(seconds: 15));
            if (response.statusCode != 200) {
              throw const FormatException('Auth settings unavailable');
            }
            final providers =
                (jsonDecode(response.body) as Map<String, dynamic>)['external']
                    as Map<String, dynamic>;
            return (
              google: providers['google'] == true,
              apple: providers['apple'] == true,
            );
          },
        ),
      );
    } catch (_) {
      runApp(GuestUnavailableApp(onRetry: main));
    }
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
