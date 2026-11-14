import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/public_preview_api.dart';
import 'package:paul_demo/search/skill_search_api.dart';

import 'public_preview_test.dart' show wireProfile;

Map<String, dynamic> page() => {
  'profiles': [wireProfile()],
  'query': '',
  'next_cursor': null,
};

void main() {
  test(
    'early public response avoids the first duplicate call but refresh stays fresh',
    () async {
      var calls = 0;
      var takes = 0;
      final api = PublicPreviewApi(
        url: Uri.parse('https://public.invalid'),
        publishableKey: 'public-key',
        bootstrap: (url, key) async {
          takes++;
          expect(url.host, 'public.invalid');
          expect(key, 'public-key');
          return jsonEncode(page());
        },
        transport: MockClient((request) async {
          calls++;
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response(jsonEncode(page()), 200);
        }),
      );
      expect(
        (await api.profiles()).profiles.single.profile.name,
        'Real community member',
      );
      expect(calls, 0);
      expect(
        api.cachedProfile((await api.profiles()).profiles.single.id),
        isNotNull,
      );
      expect(calls, 1);
      expect(takes, 1);
    },
  );

  test(
    'search, filters and pagination never receive the unfiltered early page',
    () async {
      var takes = 0;
      var calls = 0;
      final api = PublicPreviewApi(
        url: Uri.parse('https://public.invalid'),
        publishableKey: 'public-key',
        bootstrap: (_, _) async {
          takes++;
          return jsonEncode(page());
        },
        transport: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(page()), 200);
        }),
      );
      await api.profiles(query: 'Design');
      await api.profiles(namesOnly: true);
      await api.profiles(kind: SkillSearchKind.offering);
      await api.profiles(cursor: {'id': 'next'});
      expect(calls, 4);
      expect(takes, 0);
      await api.profiles();
      expect(takes, 1);
      expect(calls, 4);
    },
  );

  test(
    'failed or malformed early data follows the ordinary request and retry path',
    () async {
      for (final raw in [
        null,
        '{',
        'null',
        jsonEncode({
          'query': '',
          'profiles': [{}],
        }),
      ]) {
        var calls = 0;
        final api = PublicPreviewApi(
          url: Uri.parse('https://public.invalid'),
          publishableKey: 'public-key',
          bootstrap: (_, _) async => raw,
          transport: MockClient((_) async {
            calls++;
            return http.Response(jsonEncode(page()), 200);
          }),
        );
        expect((await api.profiles()).profiles, hasLength(1));
        expect(calls, 1);
      }
    },
  );

  test(
    'an already failed early request exposes Retry instead of another full timeout',
    () async {
      var calls = 0;
      final api = PublicPreviewApi(
        url: Uri.parse('https://public.invalid'),
        publishableKey: 'public-key',
        bootstrap: (_, _) async => '{"__paul_bootstrap_failed":true}',
        transport: MockClient((_) async {
          calls++;
          return http.Response(jsonEncode(page()), 200);
        }),
      );
      await expectLater(api.profiles(), throwsFormatException);
      expect(calls, 0);
      expect((await api.profiles()).profiles, hasLength(1));
      expect(calls, 1);
    },
  );
}
