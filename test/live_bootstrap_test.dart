import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/live/live_bootstrap.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'live_chat_api_test.dart' show token;

class _Storage extends GotrueAsyncStorage {
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bootstrap retry reuses an initialized SDK client and its valid session',
    () async {
      const id = '10000000-0000-4000-8000-000000000001';
      var requests = 0;
      await Supabase.initialize(
        url: 'https://local.invalid',
        publishableKey: 'local-key',
        debug: false,
        httpClient: MockClient((_) async {
          requests++;
          return http.Response('{}', 400);
        }),
        authOptions: FlutterAuthClientOptions(
          autoRefreshToken: false,
          detectSessionInUri: false,
          localStorage: const EmptyLocalStorage(),
          pkceAsyncStorage: _Storage(),
        ),
      );
      try {
        final client = Supabase.instance.client;
        await client.auth.setInitialSession(
          jsonEncode({
            'access_token': token(id),
            'refresh_token': 'local-refresh',
            'token_type': 'bearer',
            'expires_in': 3600,
            'user': {
              'id': id,
              'aud': 'authenticated',
              'created_at': '2026-01-01T00:00:00Z',
              'app_metadata': {},
              'user_metadata': {},
            },
          }),
        );
        final session = client.auth.currentSession;
        for (var attempt = 0; attempt < 2; attempt++) {
          final app = await buildLiveApp(
            url: 'https://local.invalid',
            key: 'local-key',
            appUrl: 'https://app.invalid',
          );
          expect(app, isA<PaulLiveApp>());
          expect(identical((app as PaulLiveApp).client, client), isTrue);
          expect(identical(client.auth.currentSession, session), isTrue);
        }
        expect(requests, 0);
      } finally {
        await Supabase.instance.dispose();
      }
    },
  );
}
