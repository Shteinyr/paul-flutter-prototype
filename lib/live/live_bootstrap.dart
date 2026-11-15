import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'browser_storage.dart';
import '../config/app_configuration.dart';
import '../platform/storage/platform_storage.dart';
import 'keep_signed_in_storage.dart';
import 'auth_callback.dart';
import 'guest_preview.dart';
import 'live_app.dart';
import 'public_preview_api.dart';

Future<Widget> buildLiveApp({
  required String url,
  required String key,
  required String appUrl,
  AppPurpose purpose = AppPurpose.review,
}) async {
  final previewUrl = Uri.tryParse(url);
  final publicPreview = previewUrl?.hasAuthority == true && key.isNotEmpty
      ? PublicPreviewApi(url: previewUrl!, publishableKey: key)
      : null;
  Future<void> retry() async => runApp(
    await buildLiveApp(url: url, key: key, appUrl: appUrl, purpose: purpose),
  );
  const probe = 'paul.live.storage.check.v1';
  try {
    await initializePlatformStorage();
    // The chat journal keeps using the strict adapter. This preflight only
    // chooses a read-only bootstrap when tab storage cannot retain operations.
    writeSessionValue(probe, '1');
    if (readSessionValue(probe) != '1') {
      throw StateError('Tab storage did not retain the probe');
    }
    removeSessionValue(probe);
  } catch (_) {
    return GuestUnavailableApp(
      onRetry: retry,
      publicPreviewRepository: publicPreview,
      message:
          'Browser storage is unavailable. Allow storage for this site, then retry to sign in. You can keep exploring the preview.',
    );
  }
  final callbackUri = Uri.base;
  final authCallback = kIsWeb
      ? isAuthCallback(callbackUri)
      : callbackUri.queryParameters['auth'] == 'callback';
  try {
    if (url.isEmpty || key.isEmpty || appUrl.isEmpty) {
      throw const FormatException('Missing live configuration');
    }
    await Supabase.initialize(
      url: url,
      publishableKey: key,
      debug: false,
      authOptions: FlutterAuthClientOptions(
        localStorage: KeepSignedInStorage(
          SharedPreferencesLocalStorage(
            persistSessionKey:
                'sb-${Uri.parse(url).host.split('.').first}-auth-token',
          ),
        ),
        detectSessionInUriPredicate: (uri) => kIsWeb
            ? isAuthCallback(uri)
            : uri.scheme == 'app.paul' && uri.host == 'login-callback',

        authFlowType: AuthFlowType.pkce,
        // The web bootstrap awaits the same SDK exchange below and retains
        // its outcome; the automatic observer would otherwise consume it twice.
        detectSessionInUri: !kIsWeb,
      ),
    );
    var callbackResult = AuthCallbackResult.none;
    if (kIsWeb && authCallback) {
      try {
        callbackResult = await completeAuthCallback(
          Supabase.instance.client,
          callbackUri,
        );
      } finally {
        clearAuthCallbackFromAddress();
      }
    }
    return PaulLiveApp(
      client: Supabase.instance.client,
      purpose: purpose,
      publicPreviewRepository: purpose == AppPurpose.app ? null : publicPreview,
      appUrl: Uri.parse(appUrl),
      authCallback: authCallback,
      authCallbackFailed: callbackResult == AuthCallbackResult.failed,
      loadAuthProviders: () async {
        final response = await http
            .get(Uri.parse('$url/auth/v1/settings'), headers: {'apikey': key})
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
    );
  } catch (_) {
    return GuestUnavailableApp(
      onRetry: retry,
      publicPreviewRepository: publicPreview,
    );
  }
}
