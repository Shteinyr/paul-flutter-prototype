import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/admin/admin_api.dart';
import 'package:paul_demo/admin/admin_view.dart';
import 'package:paul_demo/admin/managed_profile_header.dart';
import 'package:paul_demo/app.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

const _actor = '10000000-0000-4000-8000-000000000001';
const _other = '10000000-0000-4000-8000-000000000002';
const _session1 = '20000000-0000-4000-8000-000000000001';
const _session2 = '20000000-0000-4000-8000-000000000002';
const _profile = ManagedProfile(
  id: 'managed',
  name: 'Managed',
  canManage: true,
  canReply: true,
  avatarPath: 'managed/hash.png',
  updatedAt: 'v1',
);

class _Json extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

class _Fixture {
  Object? sessionId = _session1;
  String actor = _actor;
  int tokenRevision = 0;
  int downloads = 0;
  List<int> photo = [1, 2, 3];
  bool storageFails = false;
  bool denied = false;
  List<ManagedProfile> profiles = [_profile];
  final waits = <Completer<http.Response>>[];
  final contextWaits = <Completer<http.Response>>[];
  late final SupabaseClient client = SupabaseClient(
    'https://portraits.invalid',
    'test-key',
    httpClient: MockClient(handle),
    isolate: _Json(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  late final api = SupabaseAdminApi(client, _actor);

  http.Response json(Object value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json'},
  );
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/token')) {
      final jwt =
          'e30.${base64Url.encode(utf8.encode(jsonEncode({'sub': actor, 'session_id': sessionId, 'aud': 'authenticated', 'exp': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000, 'iat': tokenRevision++}))).replaceAll('=', '')}.signature';
      return json({
        'access_token': jwt,
        'refresh_token': 'local-$tokenRevision',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': actor,
          'aud': 'authenticated',
          'created_at': '2026-01-01T00:00:00Z',
          'app_metadata': {},
          'user_metadata': {},
        },
      });
    }
    if (request.url.path.endsWith('/logout')) return json({});
    if (request.url.path.startsWith('/storage/')) {
      downloads++;
      if (waits.isNotEmpty) return waits.removeAt(0).future;
      return storageFails
          ? json({'message': 'Unavailable', 'statusCode': '503'}, 503)
          : http.Response.bytes(photo, 200);
    }
    expect(request.url.path, '/functions/v1/admin');
    if (denied) return json({'code': 'managed_profile_forbidden'}, 403);
    final body = jsonDecode(request.body) as Map;
    if (body['action'] != 'context') return json({});
    if (contextWaits.isNotEmpty) return contextWaits.removeAt(0).future;
    return contextResponse(profiles);
  }

  http.Response contextResponse(List<ManagedProfile> values) => json({
    'role': 'admin',
    'profiles': [
      for (final p in values)
        {
          'id': p.id,
          'name': p.name,
          'occupation': p.occupation,
          'summary': p.summary,
          'skills': p.skills,
          'searching_skills': p.searchingSkills,
          'can_manage': p.canManage,
          'can_reply': p.canReply,
          'avatar_path': p.avatarPath,
          'updated_at': p.updatedAt,
          'disabled_at': p.disabledAt?.toIso8601String(),
        },
    ],
  });

  Future<void> login() => client.auth.signInWithPassword(
    email: 'qa@example.invalid',
    password: 'local-only',
  );
}

class _Pops extends NavigatorObserver {
  final names = <String?>[];
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    names.add(route.settings.name);
  }
}

void main() {
  late _Fixture f;
  setUp(() async {
    f = _Fixture();
    await f.login();
  });
  tearDown(() async {
    await f.client.dispose();
  });

  test(
    'same portrait shares pending and completed read across fresh unchanged context',
    () async {
      final wait = Completer<http.Response>();
      f.waits.add(wait);
      final first = f.api.photo(_profile);
      final second = f.api.photo(_profile);
      await Future<void>.delayed(Duration.zero);
      expect(f.downloads, 1);
      wait.complete(http.Response.bytes([1, 2, 3], 200));
      expect(await first, [1, 2, 3]);
      expect(await second, [1, 2, 3]);
      await f.api.context();
      await f.api.photo(_profile);
      expect(f.downloads, 1);
    },
  );

  test(
    'ordinary token refresh preserves a pending portrait in the same session',
    () async {
      final wait = Completer<http.Response>();
      f.waits.add(wait);
      final first = f.api.photo(_profile);
      await Future<void>.delayed(Duration.zero);
      await f.client.auth.refreshSession();
      wait.complete(http.Response.bytes([1, 2, 3], 200));
      expect(await first, [1, 2, 3]);
      await f.api.photo(_profile);
      expect(f.downloads, 1);
    },
  );

  for (final sameActor in [true, false]) {
    test(
      'late portrait is rejected after sign out and sign in, sameActor=$sameActor',
      () async {
        final wait = Completer<http.Response>();
        f.waits.add(wait);
        final first = f.api.photo(_profile);
        final assertion = expectLater(first, throwsA(isA<AdminException>()));
        await Future<void>.delayed(Duration.zero);
        await f.client.auth.signOut();
        f.sessionId = _session2;
        if (!sameActor) f.actor = _other;
        await f.login();
        wait.complete(http.Response.bytes([1, 2, 3], 200));
        await assertion;
        if (sameActor) {
          await f.api.photo(_profile);
          expect(f.downloads, 2);
        } else {
          await expectLater(
            f.api.photo(_profile),
            throwsA(isA<AdminException>()),
          );
          expect(f.downloads, 1);
        }
      },
    );
  }

  for (final marker in [null, 42]) {
    test(
      'missing or unreadable session marker disables reuse: $marker',
      () async {
        await f.client.auth.signOut();
        f.sessionId = marker;
        await f.login();
        await f.api.photo(_profile);
        await f.api.photo(_profile);
        expect(f.downloads, 2);
      },
    );
  }

  test('failed photo can be retried and then reused', () async {
    f.storageFails = true;
    await expectLater(f.api.photo(_profile), throwsA(isA<StorageException>()));
    f.storageFails = false;
    await f.api.photo(_profile);
    await f.api.photo(_profile);
    expect(f.downloads, 2);
  });

  for (final denied in [true, false]) {
    test(
      'fresh context invalidates a late portrait after ${denied ? 'grant denial' : 'profile removal'}',
      () async {
        final wait = Completer<http.Response>();
        f.waits.add(wait);
        final first = f.api.photo(_profile);
        final assertion = expectLater(first, throwsA(isA<AdminException>()));
        await Future<void>.delayed(Duration.zero);
        f.denied = denied;
        f.profiles = [];
        if (denied) {
          await expectLater(f.api.context(), throwsA(isA<AdminException>()));
        } else {
          expect((await f.api.context()).profiles, isEmpty);
        }
        wait.complete(http.Response.bytes([1, 2, 3], 200));
        await assertion;
      },
    );
  }

  test('new photo path rejects the old pending response', () async {
    final wait = Completer<http.Response>();
    f.waits.add(wait);
    final old = f.api.photo(_profile);
    final assertion = expectLater(old, throwsA(isA<AdminException>()));
    await Future<void>.delayed(Duration.zero);
    const next = ManagedProfile(
      id: 'managed',
      name: 'Managed',
      canManage: true,
      canReply: true,
      avatarPath: 'managed/new-hash.png',
      updatedAt: 'v2',
    );
    await f.api.photo(next);
    wait.complete(http.Response.bytes([9], 200));
    await assertion;
    await f.api.photo(next);
    expect(f.downloads, 2);
  });

  test('editing and photo removal invalidate completed reuse', () async {
    await f.api.photo(_profile);
    await f.api.command({'action': 'save'});
    await f.api.photo(_profile);
    expect(f.downloads, 2);
    const removed = ManagedProfile(
      id: 'managed',
      name: 'Managed',
      canManage: true,
      canReply: true,
      updatedAt: 'v2',
    );
    expect(await f.api.photo(removed), isNull);
    await f.api.photo(_profile);
    expect(f.downloads, 3);
  });

  test(
    'evicted pending portrait is rejected when fresh context removes access',
    () async {
      final wait = Completer<http.Response>();
      f.waits.add(wait);
      final old = f.api.photo(_profile);
      final assertion = expectLater(old, throwsA(isA<AdminException>()));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 8; i++) {
        await f.api.photo(
          ManagedProfile(
            id: 'other-$i',
            name: 'Other',
            canManage: true,
            canReply: true,
            avatarPath: 'other-$i/hash.png',
          ),
        );
      }
      f.profiles = [];
      await f.api.context();
      wait.complete(http.Response.bytes([1, 2, 3], 200));
      await assertion;
    },
  );

  for (final status in [200, 403, 500]) {
    test(
      'race107 old context $status cannot invalidate a newer portrait',
      () async {
        final oldResponse = Completer<http.Response>();
        f.contextWaits.add(oldResponse);
        final old = f.api.context();
        final oldResult = status == 200
            ? expectLater(old, completes)
            : expectLater(old, throwsA(isA<AdminException>()));
        await Future<void>.delayed(Duration.zero);
        const next = ManagedProfile(
          id: 'managed',
          name: 'Managed',
          canManage: true,
          canReply: true,
          avatarPath: 'managed/new-hash.png',
          updatedAt: 'v2',
        );
        f.profiles = [next];
        await f.api.context();
        final photoResponse = Completer<http.Response>();
        f.waits.add(photoResponse);
        final photo = f.api.photo(next);
        final photoResult = expectLater(
          photo,
          completion(orderedEquals([1, 2, 3])),
        );
        await Future<void>.delayed(Duration.zero);
        oldResponse.complete(
          status == 200
              ? f.contextResponse([_profile])
              : f.json({
                  'code': status == 403
                      ? 'managed_profile_forbidden'
                      : 'server_unavailable',
                }, status),
        );
        await oldResult;
        photoResponse.complete(http.Response.bytes([1, 2, 3], 200));
        await photoResult;
        await f.api.photo(next);
        expect(f.downloads, 1);
      },
    );
  }

  testWidgets(
    'race107 removed Admin route cannot pop Other in its delayed callback',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final observer = _Pops();
      final selected = ValueNotifier(f.api);
      var removeAdmin = false;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [observer],
          home: const Scaffold(body: Text('Home')),
        ),
      );
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: 'Other'),
            builder: (_) => const Scaffold(body: Text('Other')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: 'Admin'),
            builder: (_) => ValueListenableBuilder<SupabaseAdminApi>(
              valueListenable: selected,
              builder: (_, repository, _) {
                if (removeAdmin) {
                  removeAdmin = false;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => navigator.currentState!.pop(),
                  );
                }
                return AdminView(repository: repository);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await f.client.auth.signOut();
      f.sessionId = _session2;
      await f.login();
      removeAdmin = true;
      selected.value = SupabaseAdminApi(f.client, _actor);
      await tester.pump();
      expect(observer.names, ['Admin']);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(find.text('Other'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      selected.dispose();
    },
  );

  test('reuse is bounded to eight recent portraits', () async {
    ManagedProfile profile(int i) => ManagedProfile(
      id: 'managed-$i',
      name: 'Managed',
      canManage: true,
      canReply: true,
      avatarPath: 'managed-$i/hash.png',
    );
    for (var i = 0; i < 8; i++) {
      await f.api.photo(profile(i));
    }
    await f.api.photo(profile(0));
    expect(f.downloads, 8);
    await f.api.photo(profile(8));
    await f.api.photo(profile(1));
    expect(f.downloads, 10);
  });

  Widget adminHost(ValueNotifier<SupabaseAdminApi> selected) => MaterialApp(
    home: ValueListenableBuilder<SupabaseAdminApi>(
      valueListenable: selected,
      builder: (_, api, _) => AdminView(repository: api),
    ),
  );

  testWidgets(
    'same actor rebuild and token refresh keep the Admin portrait context',
    (tester) async {
      f.photo = (await rootBundle.load(
        'assets/people/paul-galda.png',
      )).buffer.asUint8List();
      final selected = ValueNotifier(f.api);
      await tester.pumpWidget(adminHost(selected));
      await tester.pumpAndSettle();
      expect(f.downloads, 1);
      selected.value = SupabaseAdminApi(f.client, _actor);
      await tester.pumpAndSettle();
      expect(f.downloads, 1);
      await f.client.auth.refreshSession();
      selected.value = SupabaseAdminApi(f.client, _actor);
      await tester.pumpAndSettle();
      expect(f.downloads, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      selected.dispose();
    },
  );

  for (final sameActor in [true, false]) {
    testWidgets(
      'new session clears old Admin child route and list, sameActor=$sameActor',
      (tester) async {
        f.photo = (await rootBundle.load(
          'assets/people/paul-galda.png',
        )).buffer.asUint8List();
        final selected = ValueNotifier(f.api);
        await tester.pumpWidget(adminHost(selected));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('User actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Edit user'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsWidgets);
        await f.client.auth.signOut();
        f.sessionId = _session2;
        if (!sameActor) f.actor = _other;
        await f.login();
        f.profiles = [
          const ManagedProfile(
            id: 'new',
            name: 'New profile',
            canManage: true,
            canReply: true,
          ),
        ];
        selected.value = SupabaseAdminApi(f.client, f.actor);
        await tester.pumpAndSettle();
        expect(find.text('New profile'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.text('Managed'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        selected.dispose();
      },
    );
  }

  testWidgets('repeated portrait placements share one transport read', (
    tester,
  ) async {
    f.photo = (await rootBundle.load(
      'assets/people/paul-galda.png',
    )).buffer.asUint8List();
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            for (var i = 0; i < 3; i++)
              ManagedProfileAvatar(repository: f.api, profile: _profile),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(f.downloads, 1);
    expect(
      tester
          .widgetList<ProfileAvatar>(find.byType(ProfileAvatar))
          .where((avatar) => avatar.photo != null),
      hasLength(3),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
