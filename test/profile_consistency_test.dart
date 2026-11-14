import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paul_demo/live/live_api.dart';
import 'package:paul_demo/live/live_app.dart';
import 'package:paul_demo/profile/profile_controller.dart';
import 'package:paul_demo/profile/profile_conflict_dialog.dart';
import 'package:paul_demo/push/push_api.dart' show pushSessionId;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:yet_another_json_isolate/yet_another_json_isolate.dart';

import 'support/onboarding_preferences.dart';
import 'support/quiet_chat_repository.dart';

const actor = '13200000-0000-4000-8000-000000000001';

class InlineJson extends Fake implements YAJsonIsolate {
  @override
  Future<String> encode(Object? value) async => jsonEncode(value);
  @override
  Future<dynamic> decode(String value) async => jsonDecode(value);
}

class ProfileServer {
  Map<String, dynamic> profile = {
    'id': actor,
    'name': 'Original name',
    'occupation': 'Designer',
    'summary': 'Original summary',
    'skills': ['Design'],
    'searching_skills': <String>[],
    'contact_count': 0,
    'avatar_path': '$actor/original.png',
  };
  late SupabaseClient client;
  int uploads = 0, logouts = 0, sessions = 0, networkReads = 0, downloads = 0;
  Completer<void>? networkGate, saveGate;
  Completer<void>? networkReached, saveReached;
  bool failSave = false, loseAck = false, failRead = false, failPhoto = false;
  String failureCode = 'server_unavailable';
  final requests = <Map<String, dynamic>>[];
  final receipts = <String, String>{};
  final photo = Uint8List.fromList([1, 2, 3]);
  Future<void> start({bool withPhoto = true}) async {
    if (!withPhoto) profile['avatar_path'] = null;
    client = SupabaseClient(
      'https://profile-test.invalid',
      'test-key',
      httpClient: MockClient(handle),
      isolate: InlineJson(),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.signInWithPassword(
      email: 'a@example.invalid',
      password: 'test',
    );
  }

  http.Response json(Object? value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json'},
    request: http.Request('POST', Uri.parse('https://profile-test.invalid')),
  );
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/token')) {
      final claims = base64Url
          .encode(
            utf8.encode(
              jsonEncode({
                'sub': actor,
                'aud': 'authenticated',
                'role': 'authenticated',
                'exp':
                    DateTime.now()
                        .add(const Duration(hours: 1))
                        .millisecondsSinceEpoch ~/
                    1000,
                'session_id':
                    '13200000-0000-4000-8000-${(++sessions).toString().padLeft(12, '0')}',
              }),
            ),
          )
          .replaceAll('=', '');
      return json({
        'access_token': 'e30.$claims.signature',
        'refresh_token': 'test',
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
    if (path.endsWith('/logout')) {
      logouts++;
      return json({});
    }
    if (path.endsWith('/avatar_upload_begin')) return json(null);
    if (path.startsWith('/storage/')) {
      if (request.method == 'POST') {
        uploads++;
        return json({'Key': 'ok'});
      }
      downloads++;
      if (failPhoto) return json({'message': 'photo unavailable'}, 503);
      return http.Response.bytes(photo, 200);
    }
    if (path.endsWith('/account')) {
      return json({
        'invited_registrations': 0,
        'can_message_anyone': false,
        'can_publish_community': false,
        'offering_limit': 5,
        'new_conversations_remaining': 1,
        'quota_resets_at': '2026-12-01T00:00:00Z',
      });
    }
    if (!path.endsWith('/invitations')) {
      return json({}, 404);
    }
    final body = Map<String, dynamic>.from(jsonDecode(request.body) as Map);
    if (body['action'] == 'network') {
      networkReads++;
      if (failRead) return json({'code': 'server_unavailable'}, 503);
      final snapshot = Map<String, dynamic>.from(profile);
      networkReached?.complete();
      networkReached = null;
      await networkGate?.future;
      return json({'profile': snapshot, 'contacts': []});
    }
    requests.add(body);
    saveReached?.complete();
    saveReached = null;
    await saveGate?.future;
    if (failSave) return json({'code': failureCode}, 503);
    if (body['action'] == 'save_profile') {
      profile.addAll(Map<String, dynamic>.from(body['profile'] as Map));
      return json({});
    }
    if (body['action'] == 'merge_profile') {
      final operation = body['operation_id'] as String;
      final fingerprint = jsonEncode([body['base'], body['changes']]);
      if (receipts.containsKey(operation)) {
        if (receipts[operation] != fingerprint) {
          return json({'code': 'invalid_request'}, 400);
        }
        return json({'profile': profile});
      }
      final base = body['base'] as Map, changes = body['changes'] as Map;
      for (final key in changes.keys) {
        if (jsonEncode(profile[key]) != jsonEncode(base[key]) &&
            jsonEncode(profile[key]) != jsonEncode(changes[key])) {
          return json({'code': 'profile_conflict'}, 409);
        }
      }
      profile.addAll(Map<String, dynamic>.from(changes));
      receipts[operation] = fingerprint;
      if (loseAck) {
        loseAck = false;
        return json({'code': 'server_unavailable'}, 503);
      }
      return json({'profile': profile});
    }
    return json({}, 400);
  }
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  test(
    'initial own profile is consumed once; subsequent reads fetch fresh data',
    () async {
      final server = ProfileServer();
      await server.start();
      addTearDown(server.client.dispose);
      final api = LiveApi(server.client);
      final own = (await api.network()).own!;
      final store = SupabaseProfileStore(
        api,
        actor,
        initialProfile: own,
        initialSession: pushSessionId(server.client),
      );
      expect(server.networkReads, 1);
      expect((await store.read()).photo, server.photo);
      expect(server.networkReads, 1);
      expect(server.downloads, 1);
      server.profile['name'] = 'Fresh after bootstrap';
      expect((await store.read()).name, 'Fresh after bootstrap');
      expect(server.networkReads, 2);
      expect((await store.read()).name, 'Fresh after bootstrap');
      expect(server.networkReads, 3);
      expect(server.downloads, 1);
    },
  );
  for (final mismatch in ['actor', 'session']) {
    test('initial profile with mismatched $mismatch is discarded', () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final seed = MemberProfile.fromJson({
        ...server.profile,
        'name': 'Untrusted seed',
        if (mismatch == 'actor') 'id': '13200000-0000-4000-8000-000000000099',
      });
      final store = SupabaseProfileStore(
        LiveApi(server.client),
        actor,
        initialProfile: seed,
        initialSession: mismatch == 'session'
            ? 'different-session'
            : pushSessionId(server.client),
      );
      expect((await store.read()).name, 'Original name');
      expect(server.networkReads, 1);
    });
  }
  test(
    'failed seed photo download consumes seed and retry reads the server',
    () async {
      final server = ProfileServer();
      await server.start();
      addTearDown(server.client.dispose);
      final seed = MemberProfile.fromJson(Map.of(server.profile));
      final store = SupabaseProfileStore(
        LiveApi(server.client),
        actor,
        initialProfile: seed,
        initialSession: pushSessionId(server.client),
      );
      server.failPhoto = true;
      await expectLater(store.read(), throwsA(anything));
      expect(server.networkReads, 0);
      server.failPhoto = false;
      server.profile['name'] = 'Fresh retry';
      expect((await store.read()).name, 'Fresh retry');
      expect(server.networkReads, 1);
    },
  );
  test('seed cannot be used after a same-account session change', () async {
    final server = ProfileServer();
    await server.start(withPhoto: false);
    addTearDown(server.client.dispose);
    final store = SupabaseProfileStore(
      LiveApi(server.client),
      actor,
      initialProfile: MemberProfile.fromJson(Map.of(server.profile)),
      initialSession: pushSessionId(server.client),
    );
    await server.client.auth.signInWithPassword(
      email: 'a@example.invalid',
      password: 'test',
    );
    await expectLater(store.read(), throwsA(isA<LiveApiException>()));
    expect(server.networkReads, 0);
  });
  test(
    'text edits keep the existing immutable avatar without uploads',
    () async {
      final server = ProfileServer();
      await server.start();
      addTearDown(server.client.dispose);
      final store = SupabaseProfileStore(LiveApi(server.client), actor);
      final p = await store.read();
      await store.write(p.copyWith(name: 'New name'));
      expect(server.uploads, 0);
      expect(server.profile['avatar_path'], '$actor/original.png');
    },
  );
  test(
    'stale full profile writes preserve fields changed by another client',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final a = SupabaseProfileStore(LiveApi(server.client), actor),
          b = SupabaseProfileStore(LiveApi(server.client), actor);
      final pa = await a.read(), pb = await b.read();
      await b.write(pb.copyWith(summary: 'Changed on B'));
      await a.write(pa.copyWith(name: 'Changed on A'));
      expect(server.profile['summary'], 'Changed on B');
      expect(server.profile['name'], 'Changed on A');
    },
  );
  test('same-field conflict preserves the newer saved value', () async {
    final server = ProfileServer();
    await server.start(withPhoto: false);
    addTearDown(server.client.dispose);
    final a = SupabaseProfileStore(LiveApi(server.client), actor),
        b = SupabaseProfileStore(LiveApi(server.client), actor);
    final pa = await a.read(), pb = await b.read();
    await b.write(pb.copyWith(name: 'Changed on B'));
    await expectLater(
      a.write(pa.copyWith(name: 'Changed on A')),
      throwsA(anything),
    );
    expect(server.profile['name'], 'Changed on B');
  });
  test('photo replacement uploads once and removal uploads nothing', () async {
    final server = ProfileServer();
    await server.start();
    addTearDown(server.client.dispose);
    final store = SupabaseProfileStore(LiveApi(server.client), actor);
    final p = await store.read();
    final replacement = p.copyWith(photo: Uint8List.fromList([4, 5, 6]));
    await store.write(replacement);
    expect(server.uploads, 1);
    await store.write(replacement.copyWith(summary: 'Text after replacement'));
    expect(server.uploads, 1);
    await store.write(replacement.withoutPhoto());
    expect(server.uploads, 1);
    expect(server.profile['avatar_path'], null);
  });
  test(
    'lost ACK retry keeps operation and avatar, and cannot replay across ABA',
    () async {
      final server = ProfileServer();
      await server.start();
      addTearDown(server.client.dispose);
      final store = SupabaseProfileStore(LiveApi(server.client), actor);
      final p = await store.read();
      final changed = p.copyWith(
        name: 'Changed',
        photo: Uint8List.fromList([4, 5, 6]),
      );
      server.loseAck = true;
      await expectLater(store.write(changed), throwsA(anything));
      server.profile['name'] =
          p.name; // Later device deliberately restored the base value.
      await store.write(changed);
      expect(server.uploads, 1);
      expect(server.profile['name'], p.name);
      expect(
        server.requests[0]['operation_id'],
        server.requests[1]['operation_id'],
      );
    },
  );
  test(
    'a failed response photo read retains the receipt rather than replaying an old mutation',
    () async {
      final server = ProfileServer();
      await server.start();
      addTearDown(server.client.dispose);
      final store = SupabaseProfileStore(LiveApi(server.client), actor);
      final p = await store.read();
      server.profile['avatar_path'] = '$actor/other-device.png';
      server.failPhoto = true;
      final edit = p.copyWith(name: 'My accepted edit');
      await expectLater(store.write(edit), throwsA(anything));
      server.failPhoto = false;
      server.profile['name'] = 'Original name';
      await store.write(edit);
      expect(server.profile['name'], 'Original name');
      expect(server.uploads, 0);
      expect(
        server.requests[0]['operation_id'],
        server.requests[1]['operation_id'],
      );
    },
  );
  test(
    'a clean refresh failure can be retried and does not block sign out',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      server.failRead = true;
      await controller.refresh();
      expect(controller.refreshFailed, true);
      expect(await controller.saveBeforeLeaving(), true);
      server.failRead = false;
      server.profile['name'] = 'Refreshed after failure';
      await controller.refresh();
      expect(controller.refreshFailed, false);
      expect(controller.profile.name, 'Refreshed after failure');
    },
  );
  test(
    'a corrected draft does not retry a definitively rejected offering snapshot',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final store = SupabaseProfileStore(LiveApi(server.client), actor);
      final p = await store.read();
      server.failureCode = 'offering_limit_reached';
      server.failSave = true;
      await expectLater(
        store.write(p.copyWith(skills: ['1', '2', '3', '4', '5', '6'])),
        throwsA(anything),
      );
      server.failSave = false;
      await store.write(p.copyWith(name: 'Corrected name'));
      expect(server.profile['skills'], ['Design']);
      expect(server.profile['name'], 'Corrected name');
      expect(server.requests.last['changes'], {'name': 'Corrected name'});
    },
  );
  test(
    'refresh after a lost ACK cannot reapply a patch across an ABA change',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.updateName('My accepted edit');
      server.loseAck = true;
      await controller.flush();
      expect(controller.hasUnsavedChanges, true);
      server.profile['name'] = 'Original name';
      await controller.refresh();
      expect(server.profile['name'], 'Original name');
      expect(controller.profile.name, 'Original name');
      expect(controller.hasUnsavedChanges, false);
    },
  );
  test(
    'refresh imports remote changes while preserving edits typed during the read',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      server.profile['summary'] = 'Remote summary';
      server.networkGate = Completer<void>();
      server.networkReached = Completer<void>();
      final reached = server.networkReached!;
      final refresh = controller.refresh();
      await reached.future;
      controller.updateName('Typed during refresh');
      server.networkGate!.complete();
      server.networkGate = null;
      await refresh;
      expect(controller.profile.summary, 'Remote summary');
      expect(controller.profile.name, 'Typed during refresh');
      expect(server.profile['summary'], 'Remote summary');
      expect(server.profile['name'], 'Typed during refresh');
    },
  );
  test(
    'repeated refresh cannot silently resolve a same-field conflict',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.updateName('My name');
      controller.updateOccupation('My occupation');
      server.profile['name'] = 'Other device name';
      await controller.refresh();
      expect(controller.hasConflict, true);
      expect(controller.profile.name, 'My name');
      await controller.flush();
      await controller.refresh();
      expect(controller.hasConflict, true);
      expect(server.profile['name'], 'Other device name');
      await controller.resolveConflict(keepLocal: false);
      expect(controller.profile.name, 'Other device name');
      expect(server.profile['occupation'], 'My occupation');
      expect(controller.hasUnsavedChanges, false);
    },
  );
  test(
    'explicit Keep my edits still detects a newer conflict during save',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.updateName('My name');
      server.profile['name'] = 'Remote one';
      await controller.refresh();
      server.profile['name'] = 'Remote two';
      await controller.resolveConflict(keepLocal: true);
      expect(controller.hasConflict, true);
      expect(server.profile['name'], 'Remote two');
      await controller.resolveConflict(keepLocal: true);
      expect(controller.hasConflict, false);
      expect(server.profile['name'], 'My name');
    },
  );
  test('typing a revert while a save is pending is preserved', () async {
    final server = ProfileServer();
    await server.start(withPhoto: false);
    addTearDown(server.client.dispose);
    final controller = ProfileController(
      SupabaseProfileStore(LiveApi(server.client), actor),
    );
    addTearDown(controller.dispose);
    await controller.load();
    controller.updateName('First edit');
    server.saveGate = Completer<void>();
    server.saveReached = Completer<void>();
    final reached = server.saveReached!;
    final save = controller.flush();
    await reached.future;
    controller.updateName('Original name');
    server.saveGate!.complete();
    server.saveGate = null;
    await save;
    expect(server.profile['name'], 'Original name');
    expect(controller.hasUnsavedChanges, false);
  });
  test(
    'a new session of the same account cannot reuse an old profile store',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final store = SupabaseProfileStore(LiveApi(server.client), actor);
      final p = await store.read();
      await server.client.auth.signInWithPassword(
        email: 'a@example.invalid',
        password: 'test',
      );
      await expectLater(
        store.write(p.copyWith(name: 'Previous session')),
        throwsA(isA<LiveApiException>()),
      );
      expect(server.requests, isEmpty);
    },
  );
  test(
    'refresh retries a failed write without bypassing a same-field conflict',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      server.failSave = true;
      controller.updateName('Local edit');
      await controller.flush();
      server.failSave = false;
      server.profile['name'] = 'Remote edit';
      await controller.refresh();
      expect(controller.hasConflict, true);
      await controller.flush();
      expect(server.profile['name'], 'Remote edit');
    },
  );
  testWidgets('Contacts pull refresh updates the existing own card', (
    tester,
  ) async {
    final server = ProfileServer();
    await server.start(withPhoto: false);
    addTearDown(server.client.dispose);
    await tester.pumpWidget(
      PaulLiveApp(
        client: server.client,
        appUrl: Uri.parse('https://paul.example'),
        draftPreferences: DraftPreferences(),
        chatRepositoryFor: (_) => QuietChatRepository(server.client),
      ),
    );
    await tester.pumpAndSettle();
    // Bootstrap plus at most one independent initial chat refresh.
    expect(server.networkReads, lessThanOrEqualTo(2));
    expect(find.text('Original name'), findsOneWidget);
    server.profile['name'] = 'Changed on another device';
    await tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator).first)
        .onRefresh();
    await tester.pumpAndSettle();
    expect(find.text('Changed on another device'), findsOneWidget);
    expect(find.text('Original name'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'conflict review cancel preserves edits and saved choice keeps unrelated edits',
    (tester) async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      addTearDown(server.client.dispose);
      final controller = ProfileController(
        SupabaseProfileStore(LiveApi(server.client), actor),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.updateName('Local name');
      controller.updateSummary('Local summary');
      server.profile['name'] = 'Remote name';
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => reviewProfileConflict(context, controller),
                child: const Text('Review'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Your edit: Local name'), findsOneWidget);
      expect(find.text('Saved: Remote name'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.hasConflict, true);
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use saved values'));
      await tester.pumpAndSettle();
      expect(controller.profile.name, 'Remote name');
      expect(server.profile['summary'], 'Local summary');
      expect(controller.hasConflict, false);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('failed save prevents sign out and preserves editable input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = ProfileServer();
    await server.start(withPhoto: false);
    addTearDown(server.client.dispose);
    await tester.pumpWidget(
      PaulLiveApp(
        client: server.client,
        appUrl: Uri.parse('https://paul.example'),
        draftPreferences: DraftPreferences(),
        chatRepositoryFor: (_) => QuietChatRepository(server.client),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Profile'));
    await tester.pumpAndSettle();
    server.failSave = true;
    await tester.enterText(find.byKey(const Key('name-field')), 'Unsaved name');
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(server.logouts, 0);
    expect(server.client.auth.currentUser?.id, actor);
    expect(find.text('Unsaved name'), findsOneWidget);
    expect(find.textContaining('could not be saved'), findsWidgets);
    server.failSave = false;
    await tester.ensureVisible(find.text('Retry').first);
    await tester.tap(find.text('Retry').first);
    await tester.pumpAndSettle();
    expect(server.profile['name'], 'Unsaved name');
    expect(server.logouts, 0);
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(server.logouts, 1);
    expect(server.client.auth.currentSession, null);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
