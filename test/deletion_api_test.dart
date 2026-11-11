import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/account/deletion.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'deletion_controller_test.dart' show actor, other;
import 'live_chat_api_test.dart' show token;

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

void main() {
  for (final scenario in ['self', 'managed', 'invalid-receipt']) {
    test(
      'Deletion API $scenario pins the mutation and isolates unsigned recovery',
      () async {
        final calls = <Map>[];
        final authorizations = <String?>[];
        late DeletionRecord record;
        final transport = MockClient((request) async {
          final body = jsonDecode(request.body) as Map;
          Object data;
          if (request.url.path.endsWith('/token')) {
            final id = body['email'] == 'later@example.invalid' ? other : actor;
            data = {
              'access_token': token(id),
              'refresh_token': 'test-only',
              'token_type': 'bearer',
              'expires_in': 3600,
              'user': {
                'id': id,
                'aud': 'authenticated',
                'created_at': '2026-01-01T00:00:00Z',
                'app_metadata': {},
                'user_metadata': {},
              },
            };
          } else {
            calls.add(body);
            authorizations.add(request.headers['authorization']);
            data = {
              'operation_id': scenario == 'invalid-receipt'
                  ? other
                  : record.operationId,
              'state': 'pending',
            };
          }
          return http.Response(
            jsonEncode(data),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final client = SupabaseClient(
          'https://deletion-test.invalid',
          'test-key',
          httpClient: transport,
          isolate: _Json(),
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        );
        try {
          await client.auth.signInWithPassword(
            email: 'qa@example.invalid',
            password: 'test-only',
          );
          final api = SupabaseDeletionApi(client);
          record = DeletionRecord.create(
            actor,
            profileId: scenario == 'managed' ? other : null,
            updatedAt: scenario == 'managed' ? '2026-11-11T00:00:00Z' : null,
          );
          if (scenario == 'invalid-receipt') {
            await expectLater(
              api.submit(record),
              throwsA(isA<DeletionException>()),
            );
            return;
          }
          expect((await api.submit(record)).complete, isFalse);
          expect(authorizations.single, 'Bearer ${token(actor)}');
          expect(calls.single['action'], 'delete');
          expect(calls.single['confirm'], isTrue);
          if (scenario == 'self') {
            expect(calls.single['expected_user_id'], actor);
            expect(calls.single['receipt_token'], record.receiptToken);
            await client.auth.signInWithPassword(
              email: 'later@example.invalid',
              password: 'test-only',
            );
            await api.status(record);
            expect(authorizations.last, '');
            expect(
              calls.last.keys,
              unorderedEquals([
                'action',
                'client_operation_id',
                'receipt_token',
              ]),
            );
            expect(calls.last['action'], 'deletion_status');
            await api.clearAuth(actor);
            expect(client.auth.currentUser?.id, other);
            final before = calls.length;
            await expectLater(
              api.submit(record),
              throwsA(isA<DeletionException>()),
            );
            expect(calls.length, before);
          } else {
            await api.status(record);
            expect(calls[1], calls[0]);
            expect(calls[0]['expected_updated_at'], '2026-11-11T00:00:00Z');
            expect(calls[0]['profile_id'], other);
            expect(calls[0].containsKey('receipt_token'), isFalse);
          }
        } finally {
          await client.dispose();
        }
      },
    );
  }
}
