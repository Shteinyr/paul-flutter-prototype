import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/community/community_api.dart';
import 'package:paul_demo/community/community_controller.dart';
import 'package:paul_demo/live/chat_api.dart';
import 'package:paul_demo/live/member_capabilities.dart';

import 'live_chat_controller_test.dart' show Drafts;

const requestId = '20000000-0000-4000-8000-000000000001';

CommunityRequest request({String id = requestId, bool own = false}) =>
    CommunityRequest(
      id: id,
      author: const ChatPeer(id: 'b', name: 'Author', occupation: 'Designer'),
      skill: 'Marketing',
      message: 'Help with a launch',
      createdAt: DateTime.now().toUtc(),
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 30)),
      isAuthor: own,
    );

MemberCapabilities level(int count) => MemberCapabilities(
  invitedRegistrations: count,
  canMessageAnyone: count >= 2,
  canPublishCommunity: count >= 10,
  offeringLimit: count >= 10 ? null : 5,
  newConversationsRemaining: count >= 2 ? null : 1,
  quotaResetsAt: DateTime.utc(2027),
);

class CommunityRepo implements CommunityRepository {
  @override
  String userId = 'a';
  @override
  String? currentUserId = 'a';
  final identities = StreamController<String?>.broadcast(sync: true);
  final creates = <(String, String, String)>[];
  final closes = <(String, String)>[];
  int invitations = 10;
  CommunityRequest? item = request();
  Future<CommunityReceipt> Function()? creating;
  Future<void> Function()? closing;
  Future<CommunityPage> Function(Map<String, dynamic>?)? feeding;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Future<MemberCapabilities> capabilities() async => level(invitations);
  @override
  Future<CommunityPage> feed({Map<String, dynamic>? cursor}) async =>
      feeding == null
      ? CommunityPage([?item], null, DateTime.now().toUtc())
      : feeding!(cursor);
  @override
  Future<CommunityRequest?> get(String id) async => item;
  @override
  Future<CommunityReceipt> create(
    String op,
    String skill,
    String message,
  ) async {
    creates.add((op, skill, message));
    return creating == null
        ? const CommunityReceipt(requestId, true)
        : creating!();
  }

  @override
  Future<void> close(String op, String id) async {
    closes.add((op, id));
    if (closing != null) await closing!();
  }

  @override
  Future<Uint8List?> photo(CommunityRequest request) async => null;
}

void main() {
  late CommunityRepo repository;
  late Drafts drafts;
  late CommunityController controller;
  setUp(() {
    repository = CommunityRepo();
    drafts = Drafts();
    controller = CommunityController(repository, drafts: drafts);
  });
  tearDown(() async {
    controller.dispose();
    await repository.identities.close();
  });

  Future<void> fill() async {
    await controller.prepareDraft();
    controller.updateDraft(skill: 'Marketing', message: 'Help with a launch');
  }

  test(
    'draft writes finish before create and successful cleanup is durable',
    () async {
      await fill();
      repository.creating = () async {
        final stored = jsonDecode(drafts.saved['community.a']!) as Map;
        expect(stored['operation'], repository.creates.single.$1);
        expect(stored['message'], 'Help with a launch');
        return const CommunityReceipt(requestId, true);
      };
      expect((await controller.publish())?.active, isTrue);
      expect(controller.pendingPublish, isFalse);
      expect(
        (jsonDecode(drafts.saved['community.a']!) as Map)['operation'],
        isNull,
      );
    },
  );

  test(
    'storage failure prevents request, retry keeps original operation',
    () async {
      await fill();
      drafts.failWrites = true;
      expect(await controller.publish(), isNull);
      expect(repository.creates, isEmpty);
      expect(controller.pendingPublish, isTrue);
      drafts.failWrites = false;
      expect(await controller.publish(), isNotNull);
      expect(repository.creates, hasLength(1));
    },
  );

  test(
    'unknown acknowledgement freezes payload and reload retries same operation',
    () async {
      await fill();
      repository.creating = () => Future.error(StateError('Lost response'));
      expect(await controller.publish(), isNull);
      final original = repository.creates.single;
      controller.updateDraft(skill: 'Changed', message: 'Changed');
      expect(controller.skill, original.$2);
      controller.dispose();
      controller = CommunityController(repository, drafts: drafts);
      await controller.prepareDraft();
      expect(controller.pendingPublish, isTrue);
      repository.creating = null;
      expect(await controller.publish(), isNotNull);
      expect(repository.creates.last, original);
    },
  );

  test(
    'cleanup failure after acknowledgement retries storage without new create',
    () async {
      await fill();
      repository.creating = () async {
        drafts.failWrites = true;
        return const CommunityReceipt(requestId, true);
      };
      expect(await controller.publish(), isNull);
      expect(controller.pendingPublish, isTrue);
      drafts.failWrites = false;
      expect(await controller.publish(), isNotNull);
      expect(repository.creates, hasLength(1));
    },
  );

  test(
    'expired replay clears pending without recreating the request',
    () async {
      await fill();
      repository.creating = () async =>
          const CommunityReceipt(requestId, false);
      expect((await controller.publish())?.active, isFalse);
      expect(controller.skill, isEmpty);
      expect(repository.creates, hasLength(1));
    },
  );

  test('double publish uses one remote operation', () async {
    await fill();
    final gate = Completer<CommunityReceipt>();
    repository.creating = () => gate.future;
    final first = controller.publish();
    expect(await controller.publish(), isNull);
    await Future<void>.delayed(Duration.zero);
    gate.complete(const CommunityReceipt(requestId, true));
    await first;
    expect(repository.creates, hasLength(1));
  });

  test(
    'concurrent initialization reads once and preserves newer edits',
    () async {
      final gate = Completer<String?>();
      drafts.gate = gate;
      final first = controller.prepareDraft(initialSkill: 'First');
      final second = controller.prepareDraft(initialSkill: 'Second');
      expect(identical(first, second), isTrue);
      gate.complete(null);
      await first;
      controller.updateDraft(skill: 'New input');
      await second;
      expect(controller.skill, 'New input');
      await controller.flushDraft();
    },
  );

  test('identity switch retains original durable pending request', () async {
    await fill();
    final gate = Completer<CommunityReceipt>();
    repository.creating = () => gate.future;
    final publishing = controller.publish();
    await Future<void>.delayed(Duration.zero);
    repository.currentUserId = 'b';
    repository.identities.add('b');
    gate.complete(const CommunityReceipt(requestId, true));
    expect(await publishing, isNull);
    await Future<void>.delayed(Duration.zero);
    final stored = jsonDecode(drafts.saved['community.a']!) as Map;
    expect(stored['operation'], repository.creates.single.$1);
    expect(stored['message'], 'Help with a launch');
    expect(drafts.saved.containsKey('community.b'), isFalse);
    expect(controller.current, isFalse);
  });

  test(
    'logout cancels draft timer without overwriting saved text with blanks',
    () async {
      await fill();
      repository.currentUserId = null;
      repository.identities.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stored = jsonDecode(drafts.saved['community.a']!) as Map;
      expect(stored['skill'], 'Marketing');
      expect(stored['message'], 'Help with a launch');
    },
  );

  test(
    'close storage failure blocks remote call and reload preserves operation',
    () async {
      drafts.failWrites = true;
      expect(await controller.closeRequest(requestId), isFalse);
      expect(repository.closes, isEmpty);
      drafts.failWrites = false;
      repository.closing = () => Future.error(StateError('Lost response'));
      expect(await controller.closeRequest(requestId), isFalse);
      final original = repository.closes.single;
      controller.dispose();
      controller = CommunityController(repository, drafts: drafts);
      repository.closing = null;
      expect(await controller.closeRequest(requestId), isTrue);
      expect(repository.closes.last, original);
    },
  );

  test('concurrent close and publish use independent journals', () async {
    await fill();
    final gate = Completer<void>();
    repository.closing = () => gate.future;
    final closing = controller.closeRequest(requestId);
    expect(await controller.publish(), isNotNull);
    gate.complete();
    expect(await closing, isTrue);
    final stored = jsonDecode(drafts.saved['community.a']!) as Map;
    expect(stored['operation'], isNull);
    expect(stored['skill'], isEmpty);
    expect(
      drafts.saved['community.close.a.$requestId'],
      repository.closes.single.$1,
    );
  });

  test(
    'close remains available with an unreadable unrelated compose draft',
    () async {
      drafts.saved['community.a'] = 'broken';
      await controller.prepareDraft();
      expect(controller.draftReady, isFalse);
      expect(await controller.closeRequest(requestId), isTrue);
    },
  );

  test('old pagination response cannot replace a refreshed feed', () async {
    final oldPage = Completer<CommunityPage>();
    var calls = 0;
    repository.feeding = (cursor) async {
      calls++;
      if (calls == 1) {
        return CommunityPage([request()], {'id': 'next'}, DateTime.now());
      }
      if (cursor != null) return oldPage.future;
      return CommunityPage([request(id: 'fresh')], null, DateTime.now());
    };
    await controller.refresh();
    final more = controller.loadMore();
    await controller.refresh();
    oldPage.complete(
      CommunityPage([request(id: 'stale')], null, DateTime.now()),
    );
    await more;
    expect(controller.requests.single.id, 'fresh');
  });

  test(
    'duplicate pagination entries are merged and server clock used',
    () async {
      final server = DateTime.now().toUtc().add(const Duration(hours: 3));
      repository.feeding = (cursor) async => CommunityPage(
        [request()],
        cursor == null ? {'id': 'next'} : null,
        server,
      );
      await controller.refresh();
      await controller.loadMore();
      expect(controller.requests, hasLength(1));
      expect(
        controller.serverNow.difference(server).abs(),
        lessThan(const Duration(seconds: 2)),
      );
    },
  );

  test(
    'empty, oversized and null-containing input never reaches the server',
    () async {
      await controller.prepareDraft();
      for (final invalid in ['', List.filled(65, 'x').join(), 'a\u0000']) {
        controller.updateDraft(skill: invalid, message: 'Valid');
        expect(await controller.publish(), isNull);
      }
      controller.updateDraft(
        skill: 'Valid',
        message: List.filled(2001, 'x').join(),
      );
      expect(await controller.publish(), isNull);
      expect(repository.creates, isEmpty);
      await controller.flushDraft();
    },
  );
}
