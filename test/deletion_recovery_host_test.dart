import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/account/deletion.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'deletion_controller_test.dart' show MemoryDeletionStore, actor, other;
import 'live_chat_api_test.dart' show token;
import 'support/onboarding_preferences.dart';
import 'support/quiet_chat_repository.dart';

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  for (final recovered in [actor, other]) {
    testWidgets(
      'signed-out uncommitted deletion offers sign-in and scopes retry to $recovered',
      (tester) async {
        final record = DeletionRecord.create(actor);
        final store = MemoryDeletionStore()..saved[record.key] = record;
        final deletes = <Map>[];
        final transport = MockClient((request) async {
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Map;
          Object data;
          if (request.url.path.endsWith('/token')) {
            data = {
              'access_token': token(recovered),
              'refresh_token': 'test-only',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': recovered,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            };
          } else if (body['action'] == 'deletion_status') {
            expect(request.headers['authorization'], '');
            return http.Response(
              jsonEncode({'code': 'deletion_unavailable'}),
              404,
              headers: {'content-type': 'application/json'},
            );
          } else if (body['action'] == 'delete') {
            deletes.add(body);
            data = {'operation_id': record.operationId, 'state': 'complete'};
          } else if (body['action'] == 'network') {
            data = {
              'profile': {
                'id': recovered,
                'name': 'Recovery QA',
                'occupation': '',
                'summary': 'Test',
                'skills': ['Design'],
                'searching_skills': [],
                'contact_count': 0,
                'avatar_path': null,
              },
              'contacts': [],
            };
          } else if (body['action'] == 'capabilities') {
            data = {
              'invited_registrations': 0,
              'can_message_anyone': false,
              'can_publish_community': false,
              'offering_limit': 5,
              'new_conversations_remaining': 1,
              'quota_resets_at': '2027-01-01T00:00:00Z',
            };
          } else {
            data = {};
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://recovery-test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        final chat = QuietChatRepository(client);
        try {
          await tester.pumpWidget(
            PaulLiveApp(
              client: client,
              appUrl: Uri.parse('https://test.invalid'),
              deletionStore: store,
              draftPreferences: DraftPreferences(),
              chatRepositoryFor: (_) => chat,
              recoverSignIn: () async {
                await client.auth.signInWithPassword(
                  email: 'qa@example.invalid',
                  password: 'test-only',
                );
              },
            ),
          );
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          expect(find.text('Sign in to retry deletion'), findsOneWidget);
          expect(deletes, isEmpty);
          await tester.tap(find.text('Sign in to retry deletion'));
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(seconds: 5),
          );
          if (recovered == actor) {
            expect(deletes, hasLength(1));
            expect(deletes.single, {
              'action': 'delete',
              'expected_user_id': actor,
              'client_operation_id': record.operationId,
              'receipt_token': record.receiptToken,
              'confirm': true,
            });
            expect(store.saved, isEmpty);
            expect(client.auth.currentUser, isNull);
            expect(find.text('Account deleted'), findsOneWidget);
          } else {
            expect(deletes, isEmpty);
            expect(store.saved[record.key]?.operationId, record.operationId);
            expect(client.auth.currentUser?.id, other);
          }
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(client.dispose);
        }
      },
    );
  }
}
