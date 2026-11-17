@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/public_guest_preview.dart';
import 'package:paul_demo/live/public_preview_api.dart';
import 'package:paul_demo/profile/user_profile.dart';
import 'package:paul_demo/search/skill_search_api.dart';
import 'package:paul_demo/skills/skill_catalogue.dart';

import 'public_preview_test.dart' show PublicFixture, person;

class _RealHttp extends HttpOverrides {}

const _personId = '10000000-0000-4000-8000-000000000001';

class _PortraitRepository extends PublicFixture {
  _PortraitRepository(this.read);
  final Future<PublicProfile?> Function(String id) read;
  final renewals = <String>[];
  @override
  Future<PublicProfile?> profile(String id) {
    renewals.add(id);
    return read(id);
  }
}

class _BrowsingRepository extends _PortraitRepository {
  _BrowsingRepository(this.people, super.read);
  final List<PublicProfile> people;
  @override
  PublicProfile? cachedProfile(String id) =>
      people.where((profile) => profile.id == id).firstOrNull;
  @override
  Future<PublicProfilePage> profiles({
    String query = '',
    SkillSearchKind kind = SkillSearchKind.all,
    Map<String, dynamic>? cursor,
    bool namesOnly = false,
  }) async {
    calls.add('profiles');
    return PublicProfilePage(people, query, null);
  }
}

PublicProfile _portrait(String? url, {String id = _personId}) =>
    PublicProfile(id: id, profile: person.profile, avatarUrl: url);

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 80; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (done()) return;
  }
  fail('The portrait recovery did not reach its expected state.');
}

bool _decoded(WidgetTester tester) => tester
    .widgetList<RawImage>(find.byType(RawImage))
    .any((image) => image.image != null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'NotoSans',
    )..addFont(rootBundle.load('assets/fonts/NotoSans.ttf'))).load();
  });
  late HttpServer server;
  late String origin;
  final requests = <String>[];
  String url(String token, {String id = _personId}) =>
      '$origin/storage/v1/object/sign/avatars/$id/${List.filled(64, 'a').join()}.png?token=$token';

  setUp(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    requests.clear();
    final data = await rootBundle.load('assets/people/paul-galda.png');
    final png = data.buffer.asUint8List();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final token = request.uri.queryParameters['token']!;
      requests.add(token);
      if (token.startsWith('expired')) {
        request.response.statusCode = 403;
        request.response.write('Signature expired');
      } else {
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(png);
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await server.close(force: true);
  });

  Future<void> show(
    WidgetTester tester,
    PublicProfile? profile,
    PublicPreviewRepository repository,
  ) => tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'NotoSans'),
      home: Center(
        child: PublicProfileAvatar(
          profile: profile,
          repository: repository,
          size: 65,
        ),
      ),
    ),
  );

  testWidgets(
    'expired portrait renews its card and loads the fresh signature',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final repository = _PortraitRepository(
          (_) async => _portrait(url('fresh')),
        );
        await show(tester, _portrait(url('expired')), repository);
        await _until(tester, () => _decoded(tester));
        expect(repository.renewals, [person.id]);
        expect(requests, ['expired', 'fresh']);
        await tester.pumpWidget(const SizedBox());
      }, _RealHttp());
    },
  );

  testWidgets('renewing a lower search result preserves the filter and scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await HttpOverrides.runWithHttpOverrides(() async {
      final pending = Completer<PublicProfile?>();
      final people = List.generate(16, (index) {
        final id =
            '10000000-0000-4000-8000-${(index + 1).toString().padLeft(12, '0')}';
        return PublicProfile(
          id: id,
          profile: UserProfile(
            name: 'Community member $index',
            occupation: 'Designer',
            summary: 'Public profile $index',
            skills: const ['Design'],
          ),
          avatarUrl: index == 13 ? url('expired', id: id) : null,
        );
      });
      final repository = _BrowsingRepository(people, (_) => pending.future);
      await tester.runAsync(() => SkillCatalogue.shared.suggest('Design'));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'NotoSans'),
          home: PublicGuestPreview(
            repository: repository,
            limited: true,
            onRequireSignIn: () {},
            onEditProfile: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('skill-search-field')),
        'Design',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('skill-filter-offering')));
      await tester.pumpAndSettle();
      final results = find.byKey(const Key('skill-search-results'));
      await tester.drag(results, const Offset(0, -1400));
      await _until(tester, () => repository.renewals.isNotEmpty);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: results, matching: find.byType(Scrollable)).first,
      );
      final offset = scroll.position.pixels;
      final reads = repository.calls.length;
      pending.complete(
        _portrait(url('fresh', id: people[13].id), id: people[13].id),
      );
      await _until(tester, () => _decoded(tester));
      expect(repository.renewals, [people[13].id]);
      expect(repository.calls.length, reads);
      expect(scroll.position.pixels, closeTo(offset, .5));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('skill-search-field')))
            .controller!
            .text,
        'Design',
      );
      final filter = find
          .ancestor(
            of: find.byKey(const Key('skill-filter-offering')),
            matching: find.byType(Semantics),
          )
          .first;
      expect(tester.widget<Semantics>(filter).properties.selected, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }, _RealHttp());
  });

  for (final sameUrl in [false, true]) {
    testWidgets('failed renewal is bounded, same signature=$sameUrl', (
      tester,
    ) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final repository = _PortraitRepository(
          (_) async => _portrait(url(sameUrl ? 'expired' : 'expired-again')),
        );
        await show(tester, _portrait(url('expired')), repository);
        await _until(tester, () => requests.length == 2);
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(repository.renewals, [person.id]);
        expect(requests, hasLength(2));
        expect(_decoded(tester), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _RealHttp());
    });
  }

  for (final deleted in [false, true]) {
    testWidgets('removed portrait/profile stops renewal, deleted=$deleted', (
      tester,
    ) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final repository = _PortraitRepository(
          (_) async => deleted ? null : _portrait(null),
        );
        await show(tester, _portrait(url('expired')), repository);
        await _until(
          tester,
          () =>
              repository.renewals.isNotEmpty &&
              find.byType(Image).evaluate().isEmpty,
        );
        expect(repository.renewals, [person.id]);
        expect(requests, ['expired']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _RealHttp());
    });
  }

  testWidgets('a card without a portrait does not request renewal', (
    tester,
  ) async {
    final repository = _PortraitRepository(
      (_) async => throw StateError('unexpected'),
    );
    await show(tester, _portrait(null), repository);
    await tester.pumpAndSettle();
    expect(repository.renewals, isEmpty);
    expect(requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final replaceIdentity in [false, true]) {
    testWidgets(
      'a pending old renewal cannot replace a new card, new identity=$replaceIdentity',
      (tester) async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final pending = Completer<PublicProfile?>();
          final repository = _PortraitRepository((_) => pending.future);
          await show(tester, _portrait(url('expired')), repository);
          await _until(tester, () => repository.renewals.isNotEmpty);
          final nextId = replaceIdentity
              ? '10000000-0000-4000-8000-000000000002'
              : person.id;
          await show(
            tester,
            _portrait(url('current', id: nextId), id: nextId),
            repository,
          );
          await _until(tester, () => _decoded(tester));
          pending.complete(null);
          await tester.pump();
          await tester.pump();
          expect(_decoded(tester), isTrue);
          expect(repository.renewals, [person.id]);
          expect(requests, ['expired', 'current']);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        }, _RealHttp());
      },
    );
  }

  testWidgets('disposing a card ignores its pending renewal', (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final pending = Completer<PublicProfile?>();
      final repository = _PortraitRepository((_) => pending.future);
      await show(tester, _portrait(url('expired')), repository);
      await _until(tester, () => repository.renewals.isNotEmpty);
      await tester.pumpWidget(const SizedBox());
      pending.complete(_portrait(url('fresh')));
      await tester.pump();
      expect(requests, ['expired']);
      expect(tester.takeException(), isNull);
    }, _RealHttp());
  });

  testWidgets(
    'failed profile read stays bounded and leaves a safe placeholder',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final repository = _PortraitRepository(
          (_) async => throw StateError('offline'),
        );
        await show(tester, _portrait(url('expired')), repository);
        await _until(tester, () => repository.renewals.isNotEmpty);
        for (var frame = 0; frame < 8; frame++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(repository.renewals, [person.id]);
        expect(requests, ['expired']);
        expect(_decoded(tester), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }, _RealHttp());
    },
  );
}
