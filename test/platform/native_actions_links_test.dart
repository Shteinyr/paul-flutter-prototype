import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:paul_demo/live/invitation_actions_types.dart';
import 'package:paul_demo/platform/invitations/native_invitation_actions.dart';
import 'package:paul_demo/platform/links/incoming_links.dart';

class _Links implements IncomingLinkSource {
  final initialLink = Completer<Uri?>();
  final events = StreamController<Uri>.broadcast(sync: true);
  @override
  Future<Uri?> initial() => initialLink.future;
  @override
  Stream<Uri> get links => events.stream;
}

void main() {
  const token =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final base = Uri.parse('https://paul.example/preview');
  final callback = Uri.parse('com.paul.app://login-callback');
  final parser = IncomingLinkParser(
    invitationBase: base,
    oauthCallback: callback,
  );

  for (final fragment in ['invite=$token', 'invite=12345678']) {
    test(
      'accepts a valid invitation at the configured public endpoint: $fragment',
      () {
        expect(
          parser.parse(base.replace(fragment: fragment)),
          isA<InvitationLink>(),
        );
      },
    );
  }
  for (final link in [
    'https://attacker.example/preview#invite=$token',
    'http://paul.example/preview#invite=$token',
    'https://user@paul.example/preview#invite=$token',
    'https://paul.example/other#invite=$token',
    'https://paul.example/preview#invite=bad',
    'https://paul.example/preview?invite=$token&invite=$token',
    'https://paul.example/preview#invite=$token&%69nvite=$token',
    'https://paul.example/preview?invite=$token#invite=$token',
    'com.paul.app://login-callback?code=secret&invite=$token',
    'https://attacker.example/?code=secret',
    'com.paul.app://login-callback?code=first&code=second',
  ]) {
    test(
      'rejects untrusted or ambiguous app link ${Uri.parse(link).host}/${Uri.parse(link).path}',
      () {
        expect(parser.parse(Uri.parse(link)), isNull);
      },
    );
  }
  test(
    'OAuth callback is classified without being redeemed as an invitation',
    () {
      expect(
        parser.parse(
          callback.replace(queryParameters: {'code': 'authorization-code'}),
        ),
        isA<OAuthReturnLink>(),
      );
      expect(
        parser.parse(
          callback.replace(queryParameters: {'error': 'access_denied'}),
        ),
        isA<OAuthReturnLink>(),
      );
    },
  );

  test(
    'hot link wins over an older initial URI and duplicates are bounded',
    () async {
      final source = _Links();
      var elapsed = Duration.zero;
      final listener = IncomingLinkListener(
        source: source,
        parser: parser,
        elapsed: () => elapsed,
      );
      final received = <IncomingLink>[];
      final starting = listener.start(received.add);
      final hot = base.replace(fragment: 'invite=$token');
      source.events.add(hot);
      source.initialLink.complete(base.replace(fragment: 'invite=12345678'));
      await starting;
      expect(received, hasLength(1));
      expect((received.single as InvitationLink).credential, token);
      source.events.add(hot);
      expect(received, hasLength(1));
      elapsed = const Duration(seconds: 31);
      source.events.add(hot);
      expect(received, hasLength(2));
      await listener.dispose();
      source.events.add(base.replace(fragment: 'invite=12345678'));
      expect(received, hasLength(2));
      await source.events.close();
    },
  );

  test('late initial link after disposal has no effect', () async {
    final source = _Links();
    final listener = IncomingLinkListener(source: source, parser: parser);
    final received = <IncomingLink>[];
    final starting = listener.start(received.add);
    await listener.dispose();
    source.initialLink.complete(base.replace(fragment: 'invite=$token'));
    await starting;
    expect(received, isEmpty);
    await source.events.close();
  });

  test(
    'native contact picker returns only the selected contact and maps cancellation',
    () async {
      var cancel = false;
      final actions = NativeInvitationActions(
        selectContact: () async => cancel
            ? null
            : const InvitationContact(name: 'Selected', phones: ['+123456789']),
      );
      final selected = await actions.pickContacts();
      expect(selected.contacts, hasLength(1));
      expect(selected.contacts.single.name, 'Selected');
      cancel = true;
      expect(
        (await actions.pickContacts()).result,
        InvitationActionResult.cancelled,
      );
    },
  );

  test(
    'contact permission denial and missing plugin expose recoverable results',
    () async {
      final denied = NativeInvitationActions(
        selectContact: () async =>
            throw PlatformException(code: 'permission_denied'),
      );
      expect(
        (await denied.pickContacts()).result,
        InvitationActionResult.denied,
      );
      final missing = NativeInvitationActions(
        selectContact: () async => throw MissingPluginException(),
      );
      expect(
        (await missing.pickContacts()).result,
        InvitationActionResult.unavailable,
      );
    },
  );

  test(
    'SMS composes only a sanitized phone URI and rejects injected fields',
    () async {
      final requested = <Uri>[];
      final actions = NativeInvitationActions(
        launchSms: (uri) async {
          requested.add(uri);
          return true;
        },
      );
      expect(
        await actions.openSms('+1 (234) 567-890'),
        InvitationActionResult.completed,
      );
      expect(requested.single.toString(), 'sms:+1234567890');
      expect(
        await actions.openSms('+123?body=untrusted'),
        InvitationActionResult.failed,
      );
      expect(requested, hasLength(1));
    },
  );

  test(
    'share distinguishes user cancellation, successful invocation and errors',
    () async {
      var status = ShareResultStatus.success;
      var copied = '';
      final actions = NativeInvitationActions(
        shareText: (_) async => ShareResult('', status),
        copyText: (text) async => copied = text,
      );
      expect(
        await actions.share('invitation'),
        InvitationActionResult.completed,
      );
      status = ShareResultStatus.unavailable;
      expect(
        await actions.share('invitation'),
        InvitationActionResult.completed,
      );
      status = ShareResultStatus.dismissed;
      expect(
        await actions.share('invitation'),
        InvitationActionResult.cancelled,
      );
      expect(
        await actions.copy('invitation'),
        InvitationActionResult.completed,
      );
      expect(copied, 'invitation');
    },
  );
}
