import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/session_avatar_cache.dart';

void main() {
  test(
    'shares a pending download and reuses its bytes across surfaces',
    () async {
      final cache = SessionAvatarCache();
      final download = Completer<Uint8List>();
      var reads = 0;
      Future<Uint8List> load() {
        reads++;
        return download.future;
      }

      final list = cache.read('julia', 'v1', load);
      final profile = cache.read('julia', 'v1', load);
      expect(identical(list, profile), isTrue);
      download.complete(Uint8List.fromList([1, 2, 3]));
      final bytes = await list;
      expect(await cache.read('julia', 'v1', load), same(bytes));
      expect(cache.peek('julia', 'v1'), same(bytes));
      expect(reads, 1);
    },
  );

  test(
    'failed downloads are retryable and photo versions stay distinct',
    () async {
      final cache = SessionAvatarCache();
      await expectLater(
        cache.read('julia', 'v1', () async => throw StateError('offline')),
        throwsStateError,
      );
      await cache.read('julia', 'v1', () async => Uint8List.fromList([1]));
      await cache.read('julia', 'v2', () async => Uint8List.fromList([2]));
      expect(cache.peek('julia', 'v2'), [2]);
      expect(
        await cache.read('julia', null, () async => fail('no path')),
        isNull,
      );
      expect(cache.peek('julia', 'v1'), isNull);
      expect(cache.peek('julia', 'v2'), isNull);
    },
  );

  test('logout or eviction discards late photo responses', () async {
    final cache = SessionAvatarCache();
    final old = Completer<Uint8List>();
    final pending = cache.read('julia', 'v1', () => old.future);
    cache.clear();
    await cache.read('julia', 'v1', () async => Uint8List.fromList([2]));
    old.complete(Uint8List.fromList([1]));
    expect(await pending, isNull);
    expect(cache.peek('julia', 'v1'), [2]);
    final removed = Completer<Uint8List>();
    final removedRead = cache.read('paul', 'v1', () => removed.future);
    cache.evict('paul');
    removed.complete(Uint8List.fromList([3]));
    expect(await removedRead, isNull);
  });

  test(
    'bounds retained bytes and evicts the least recently used portrait',
    () async {
      final cache = SessionAvatarCache(maxEntries: 2, maxBytes: 4);
      Future<void> add(String id) async {
        await cache.read(id, 'v1', () async => Uint8List.fromList([1, 2]));
      }

      await add('a');
      await add('b');
      cache.peek('a', 'v1');
      await add('c');
      expect(cache.peek('a', 'v1'), isNotNull);
      expect(cache.peek('b', 'v1'), isNull);
      expect(cache.peek('c', 'v1'), isNotNull);
      await cache.read('large', 'v1', () async => Uint8List(5));
      expect(cache.peek('large', 'v1'), isNull);
    },
  );
}
