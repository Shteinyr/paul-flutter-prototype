import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/public_avatar_image.dart';

const _owner = '10000000-0000-4000-8000-000000000001';
final _hash = List.filled(64, 'a').join();
String _url(String token, {String? path}) =>
    'https://one.invalid/storage/v1/object/sign/avatars/$_owner/${path ?? '$_hash.png'}?token=$token';

Future<PublicAvatarImageKey> _key(String url, {double scale = 1}) =>
    PublicAvatarImage(url, scale: scale).obtainKey(ImageConfiguration.empty);

void main() {
  test(
    'only the signature changes the transport, not an immutable image key',
    () async {
      final first = PublicAvatarImage(_url('first-secret'));
      final next = PublicAvatarImage(_url('next-secret'));
      expect(first, isNot(next));
      final a = await first.obtainKey(ImageConfiguration.empty);
      final b = await next.obtainKey(ImageConfiguration.empty);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), isNot(contains('secret')));
      expect(first.toString(), isNot(contains('secret')));
      expect(first.toString(), isNot(contains('https:')));
    },
  );

  test('origin, owner, version and scale remain distinct', () async {
    final original = _url('first');
    final key = await _key(original);
    for (final other in [
      original.replaceFirst('one.invalid', 'two.invalid'),
      original.replaceFirst('one.invalid', 'one.invalid:8443'),
      original.replaceFirst('https:', 'http:'),
      original.replaceFirst(_owner, '20000000-0000-4000-8000-000000000001'),
      original.replaceFirst(_hash, List.filled(64, 'b').join()),
    ]) {
      expect(await _key(other), isNot(key));
    }
    expect(await _key(original, scale: 2), isNot(key));
  });

  test(
    'legacy, transforms and unrecognized routes preserve the full URL',
    () async {
      for (final url in [
        _url('first', path: 'avatar.png'),
        _url('first', path: '${_hash.substring(1)}.png'),
        _url('first', path: '$_hash.jpg'),
        _url('first').replaceFirst('/object/sign/', '/render/image/sign/'),
        _url('first').replaceFirst('/avatars/', '/other/'),
        '${_url('first')}&width=65',
        '${_url('first')}&token=duplicate',
        '${_url('first')}#fragment',
        _url('first').replaceFirst('one.invalid', 'user@one.invalid'),
        _url('first').replaceFirst('storage', '%73torage'),
        _url('first').replaceFirst('https://one.invalid', ''),
      ]) {
        final key = await _key(url);
        expect(await _key(url.replaceAll('first', 'second')), isNot(key));
        expect(key.toString(), isNot(contains('first')));
      }
    },
  );

  test(
    'ResizeImage keys preserve immutable reuse and decoded dimensions',
    () async {
      final first = ResizeImage(PublicAvatarImage(_url('first')), width: 195);
      final next = ResizeImage(PublicAvatarImage(_url('second')), width: 195);
      final larger = ResizeImage(PublicAvatarImage(_url('second')), width: 390);
      expect(
        await first.obtainKey(ImageConfiguration.empty),
        await next.obtainKey(ImageConfiguration.empty),
      );
      expect(
        await first.obtainKey(ImageConfiguration.empty),
        isNot(await larger.obtainKey(ImageConfiguration.empty)),
      );
    },
  );
}
