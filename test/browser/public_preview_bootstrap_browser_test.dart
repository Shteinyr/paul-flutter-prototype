@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/public_preview_api.dart';

import '../public_preview_test.dart' show wireProfile;

@JS('paulPublicPreviewBootstrap')
external set _bridge(JSObject? value);

void main() {
  tearDown(() => _bridge = null);
  test(
    'a slow early response is awaited without a second public request',
    () async {
      final reply = Completer<String>();
      final bridge = JSObject();
      bridge.setProperty(
        'take'.toJS,
        ((JSString endpoint, JSString key) {
          return reply.future.then((value) => value.toJS).toJS;
        }).toJS,
      );
      _bridge = bridge;
      var requests = 0;
      final body = jsonEncode({
        'query': '',
        'profiles': [wireProfile()],
        'next_cursor': null,
      });
      final api = PublicPreviewApi(
        url: Uri.parse('https://public.invalid'),
        publishableKey: 'public-key',
        transport: MockClient((_) async {
          requests++;
          return http.Response(body, 200);
        }),
      );
      final loading = api.profiles();
      // A real browser run caught the previous 2s bridge timeout duplicating a
      // still-pending early request. Wait beyond that exact regression boundary.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      final duplicated = requests;
      reply.complete(body);
      expect((await loading).profiles, hasLength(1));
      expect(duplicated, 0);
      expect(requests, 0);
    },
  );
}
