@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/public_avatar_image.dart';

class _RealHttp extends HttpOverrides {}

Future<ImageInfo> _image(ImageProvider provider) {
  final result = Completer<ImageInfo>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (image, _) {
      stream.removeListener(listener);
      result.complete(image);
    },
    onError: (Object error, StackTrace? stack) {
      stream.removeListener(listener);
      result.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  return result.future.timeout(const Duration(seconds: 10));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer server;
  late String origin;
  final paths = <String>[];
  const owner = '10000000-0000-4000-8000-000000000001';
  final hash = List.filled(64, 'a').join();
  String url(String token, {String? filename}) =>
      '$origin/storage/v1/object/sign/avatars/$owner/${filename ?? '$hash.png'}?token=$token';
  Future<T> real<T>(Future<T> Function() body) =>
      HttpOverrides.runWithHttpOverrides(body, _RealHttp());

  setUp(() async {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    paths.clear();
    final data = await rootBundle.load('assets/people/paul-galda.png');
    final png = data.buffer.asUint8List();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      paths.add(request.uri.toString());
      request.response.headers.set('Cache-Control', 'no-store');
      if (request.uri.queryParameters['token'] == 'expired-secret') {
        request.response.statusCode = 403;
        request.response.write('Rejected signature expired-secret');
      } else if (request.uri.queryParameters['token'] == 'invalid-png-secret') {
        request.response.write('Not an image');
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

  test(
    'rotated signatures share one real wire fetch, including resized images',
    () async {
      await real(() async {
        final a = ResizeImage(PublicAvatarImage(url('first')), width: 24);
        final b = ResizeImage(PublicAvatarImage(url('second')), width: 24);
        final images = await Future.wait([_image(a), _image(b)]);
        for (final image in images) {
          expect(image.image.width, 24);
          image.dispose();
        }
        expect(paths, hasLength(1));
        final hit = await _image(b);
        hit.dispose();
        expect(paths, hasLength(1));
        final next = await _image(
          ResizeImage(
            PublicAvatarImage(
              url('third', filename: '${List.filled(64, 'b').join()}.png'),
            ),
            width: 24,
          ),
        );
        next.dispose();
        expect(paths, hasLength(2));
      });
    },
  );

  test(
    'legacy filenames do not combine different signed transport URLs',
    () async {
      await real(() async {
        for (final token in ['first', 'second']) {
          final image = await _image(
            PublicAvatarImage(url(token, filename: 'avatar.png')),
          );
          image.dispose();
        }
        expect(paths, hasLength(2));
      });
    },
  );

  test(
    'list and profile use one fixed decode key across signature changes',
    () async {
      await real(() async {
        final list = publicAvatarImage(url('list-65'));
        final profile = publicAvatarImage(url('profile-144'));
        final a = await _image(list);
        final b = await _image(profile);
        expect(a.image.width, lessThanOrEqualTo(publicAvatarDecodeWidth));
        expect(b.image.width, a.image.width);
        expect(paths, hasLength(1));
        a.dispose();
        b.dispose();
      });
    },
  );

  for (final resized in [false, true]) {
    test(
      'failed signature is evicted and a new signature retries, resized=$resized',
      () async {
        await real(() async {
          ImageProvider provider(String token) {
            final avatar = PublicAvatarImage(url(token));
            return resized ? ResizeImage(avatar, width: 24) : avatar;
          }

          await expectLater(
            _image(provider('expired-secret')),
            throwsA(
              isA<PublicAvatarImageLoadException>().having(
                (e) => e.toString(),
                'safe diagnostic',
                isNot(contains('secret')),
              ),
            ),
          );
          // ResizeImage evicts its outer key in a microtask, as NetworkImage
          // does. A widget's next frame runs after that eviction.
          await Future<void>.delayed(Duration.zero);
          final image = await _image(provider('fresh-secret'));
          image.dispose();
          expect(paths, hasLength(2));
          expect(paths.last, contains('token=fresh-secret'));
          final cached = await _image(provider('next-secret'));
          cached.dispose();
          expect(paths, hasLength(2));
        });
      },
    );
  }

  test(
    'evicted decoded data reloads with the current URL, never the old token',
    () async {
      await real(() async {
        final first = PublicAvatarImage(url('expired-later-secret'));
        final image = await _image(first);
        image.dispose();
        await first.evict();
        final next = await _image(PublicAvatarImage(url('current-secret')));
        next.dispose();
        expect(paths, hasLength(2));
        expect(paths.last, contains('token=current-secret'));
      });
    },
  );

  test(
    'decoder failure stays sanitized and does not poison future signatures',
    () async {
      await real(() async {
        await expectLater(
          _image(PublicAvatarImage(url('invalid-png-secret'))),
          throwsA(isA<PublicAvatarImageLoadException>()),
        );
        final image = await _image(PublicAvatarImage(url('valid-next-secret')));
        image.dispose();
        expect(paths, hasLength(2));
      });
    },
  );
}
