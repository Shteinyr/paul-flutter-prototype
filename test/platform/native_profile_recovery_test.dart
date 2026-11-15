import 'dart:io';
import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:paul_demo/live/live_api.dart';
import 'package:paul_demo/platform/storage/sqlite_adapters.dart';
import 'package:paul_demo/platform/storage/sqlite_journal_store.dart';

import '../profile_consistency_test.dart' show ProfileServer, actor;

class _LostUploadServer extends ProfileServer {
  final objects = <String, Uint8List>{};
  final attemptedPaths = <String>[];
  bool loseUploadAck = true;

  @override
  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.startsWith('/storage/') && request.method == 'POST') {
      final path = request.url.path;
      attemptedPaths.add(path);
      if (objects.containsKey(path)) {
        return json({
          'message': 'Already exists',
          'error': 'Duplicate',
          'statusCode': '409',
        }, 409);
      }
      var file = request.bodyBytes;
      final type = request.headers['content-type'] ?? '';
      if (type.startsWith('multipart/')) {
        final boundary = type.split('boundary=').last.replaceAll('"', '');
        final multipart = latin1.decode(request.bodyBytes);
        final start = multipart.lastIndexOf('\r\n\r\n') + 4;
        final end = multipart.indexOf('\r\n--$boundary', start);
        file = Uint8List.fromList(
          latin1.encode(multipart.substring(start, end)),
        );
      }
      objects[path] = Uint8List.fromList(file);
      uploads++;
      if (loseUploadAck) {
        loseUploadAck = false;
        return json({'message': 'ACK lost'}, 503);
      }
      return json({'Key': 'saved'});
    }
    if (request.url.path.startsWith('/storage/') && request.method == 'GET') {
      final bytes = objects[request.url.path];
      if (bytes != null) return http.Response.bytes(bytes, 200);
    }
    return super.handle(request);
  }
}

class _AdmissionServer extends ProfileServer {
  bool admitted = true;
  @override
  Future<http.Response> handle(http.Request request) async {
    if (!admitted && request.url.path.startsWith('/functions/')) {
      return json({'code': 'session_admission_required'}, 403);
    }
    return super.handle(request);
  }
}

void main() {
  late Directory directory;
  late String path;
  late SqliteJournalStore database;
  setUp(() {
    directory = (Directory(
      '.dart_tool',
    )..createSync(recursive: true)).createTempSync('profile-recovery-');
    path = '${directory.absolute.path}/journal.sqlite';
    database = SqliteJournalStore.open(path);
  });
  tearDown(() {
    database.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'SupabaseProfileStore replays a committed merge receipt after restart',
    () async {
      final server = ProfileServer();
      await server.start(withPhoto: false);
      try {
        var journal = SqliteProfileWriteJournal(database);
        var profile = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        final before = await profile.read();
        server.loseAck = true;
        await expectLater(
          profile.save(before.copyWith(name: 'Recovered name')),
          throwsA(isA<LiveApiException>()),
        );
        final original = (await journal.read(actor, actor))!;
        expect(server.receipts, hasLength(1));
        database.close();
        database = SqliteJournalStore.open(path);
        journal = SqliteProfileWriteJournal(database);
        profile = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        final after = await profile.read();
        expect(after.name, 'Recovered name');
        expect(server.receipts, hasLength(1));
        expect(server.requests.last['operation_id'], original.operationId);
        expect(await journal.read(actor, actor), isNull);
      } finally {
        await server.client.dispose();
      }
    },
  );

  test(
    'avatar intent precedes upload and a lost ACK reuses verified immutable bytes',
    () async {
      final server = _LostUploadServer();
      await server.start(withPhoto: false);
      try {
        var journal = SqliteProfileWriteJournal(database);
        var profile = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        final before = await profile.read();
        final photo = Uint8List.fromList([4, 5, 6]);
        await expectLater(
          profile.save(before.copyWith(photo: photo)),
          throwsA(anything),
        );
        final pending = (await journal.read(actor, actor))!;
        expect(pending.uploadRequired, isTrue);
        expect(pending.uploaded, isFalse);
        expect(pending.profile.photo, photo);
        expect(server.uploads, 1);
        database.close();
        database = SqliteJournalStore.open(path);
        journal = SqliteProfileWriteJournal(database);
        profile = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        final after = await profile.read();
        expect(after.photo, photo);
        expect(server.attemptedPaths, hasLength(2));
        expect(server.attemptedPaths.toSet(), hasLength(1));
        expect(server.uploads, 1);
        expect(server.receipts, hasLength(1));
        expect(await journal.read(actor, actor), isNull);
      } finally {
        await server.client.dispose();
      }
    },
  );
  test(
    'fresh admitted session for the same owner replays the original receipt',
    () async {
      final server = _AdmissionServer();
      await server.start(withPhoto: false);
      try {
        final journal = SqliteProfileWriteJournal(database);
        final previous = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        final before = await previous.read();
        server.loseAck = true;
        await expectLater(
          previous.save(before.copyWith(name: 'Preserved edit')),
          throwsA(isA<LiveApiException>()),
        );
        final pending = (await journal.read(actor, actor))!;
        await server.client.auth.signInWithPassword(
          email: 'a@example.invalid',
          password: 'test',
        );
        server.admitted = false;
        final blocked = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        await expectLater(blocked.read(), throwsA(isA<LiveApiException>()));
        expect(
          (await journal.read(actor, actor))!.operationId,
          pending.operationId,
        );
        await expectLater(previous.read(), throwsA(isA<LiveApiException>()));
        server.admitted = true;
        final recovered = SupabaseProfileStore(
          LiveApi(server.client),
          actor,
          journal: journal,
        );
        expect((await recovered.read()).name, 'Preserved edit');
        expect(server.requests.last['operation_id'], pending.operationId);
        expect(server.receipts, hasLength(1));
        expect(await journal.read(actor, actor), isNull);
      } finally {
        await server.client.dispose();
      }
    },
  );
}
