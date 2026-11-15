import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

sealed class IncomingLink {
  const IncomingLink();
}

class InvitationLink extends IncomingLink {
  const InvitationLink(this.credential);
  final String credential;
}

class OAuthReturnLink extends IncomingLink {
  const OAuthReturnLink(this.uri);
  final Uri uri;
}

/// Separate public invitation URLs from the native OAuth callback. Never
/// exchange credentials here: Supabase's single callback observer owns that.
class IncomingLinkParser {
  const IncomingLinkParser({
    required this.invitationBase,
    required this.oauthCallback,
  });
  final Uri invitationBase;
  final Uri oauthCallback;

  bool _sameEndpoint(Uri a, Uri b) =>
      a.scheme == b.scheme &&
      a.host == b.host &&
      a.port == b.port &&
      a.path.replaceAll(RegExp(r'/$'), '') ==
          b.path.replaceAll(RegExp(r'/$'), '');

  IncomingLink? parse(Uri uri) {
    if (uri.userInfo.isNotEmpty || uri.toString().length > 8192) return null;
    try {
      final query = uri.queryParametersAll;
      final fragment = <String, String>{};
      for (final part
          in uri.fragment.split('&').where((part) => part.isNotEmpty)) {
        final equals = part.indexOf('=');
        final key = Uri.decodeQueryComponent(
          equals < 0 ? part : part.substring(0, equals),
        );
        final value = Uri.decodeQueryComponent(
          equals < 0 ? '' : part.substring(equals + 1),
        );
        if (fragment.containsKey(key)) return null;
        fragment[key] = value;
      }
      if (uri.scheme == oauthCallback.scheme &&
          uri.host == 'invite' &&
          uri.path.isEmpty) {
        if (query.values.any((values) => values.length != 1) ||
            uri.fragment.isNotEmpty ||
            query.keys.any((key) => key != 'invite' && key != 'code') ||
            query.length != 1) {
          return null;
        }
        final credential = query['invite']?.single ?? query['code']?.single;
        return credential != null &&
                RegExp(r'^(?:[a-f0-9]{64}|[0-9]{8})$').hasMatch(credential)
            ? InvitationLink(credential)
            : null;
      }
      final auth =
          query.keys.any(
            {'code', 'error', 'error_description', 'access_token'}.contains,
          ) ||
          fragment.keys.any(
            {'code', 'error', 'error_description', 'access_token'}.contains,
          );
      if (auth) {
        if (!_sameEndpoint(uri, oauthCallback) ||
            query.containsKey('invite') ||
            fragment.containsKey('invite')) {
          return null;
        }
        if (query.values.any((values) => values.length != 1)) return null;
        return OAuthReturnLink(uri);
      }
      if (uri.scheme != 'https' || !_sameEndpoint(uri, invitationBase)) {
        return null;
      }
      if (query.containsKey('invite') && fragment.containsKey('invite')) {
        return null;
      }
      final credentials = query['invite'];
      if (credentials != null && credentials.length != 1) return null;
      if (fragment.keys.where((key) => key == 'invite').isNotEmpty &&
          uri.fragment
                  .split('&')
                  .where((part) => part.startsWith('invite='))
                  .length !=
              1) {
        return null;
      }
      final credential = credentials?.single ?? fragment['invite'];
      if (credential == null ||
          !RegExp(r'^(?:[a-f0-9]{64}|[0-9]{8})$').hasMatch(credential)) {
        return null;
      }
      return InvitationLink(credential);
    } on FormatException {
      return null;
    }
  }
}

abstract interface class IncomingLinkSource {
  Future<Uri?> initial();
  Stream<Uri> get links;
}

class NativeIncomingLinkSource implements IncomingLinkSource {
  NativeIncomingLinkSource([AppLinks? links]) : _links = links ?? AppLinks();
  final AppLinks _links;
  @override
  Future<Uri?> initial() => _links.getInitialLink();
  @override
  Stream<Uri> get links => _links.uriLinkStream;
}

class IncomingLinkListener {
  IncomingLinkListener({
    required this.source,
    required this.parser,
    Duration Function()? elapsed,
  }) : _elapsed = elapsed {
    _clock.start();
  }
  final IncomingLinkSource source;
  final IncomingLinkParser parser;
  final Duration Function()? _elapsed;
  final _clock = Stopwatch();
  StreamSubscription<Uri>? _subscription;
  bool _disposed = false;
  bool _started = false;
  String? _previousDigest;
  Duration? _previousAt;

  Future<void> start(
    void Function(IncomingLink) onLink, {
    void Function()? onError,
  }) async {
    if (_started || _disposed) return;
    _started = true;
    void receive(Uri uri) {
      if (_disposed) return;
      final link = parser.parse(uri);
      if (link == null) return;
      final digest = sha256.convert(utf8.encode(uri.toString())).toString();
      final now = _elapsed?.call() ?? _clock.elapsed;
      if (_previousDigest == digest &&
          _previousAt != null &&
          now - _previousAt! < const Duration(seconds: 30)) {
        return;
      }
      _previousDigest = digest;
      _previousAt = now;
      onLink(link);
    }

    var receivedLive = false;
    _subscription = source.links.listen(
      (uri) {
        receivedLive = true;
        receive(uri);
      },
      onError: (Object _) {
        if (!_disposed) onError?.call();
      },
    );
    try {
      final uri = await source.initial();
      if (uri != null && !receivedLive) receive(uri);
    } catch (_) {
      if (!_disposed) onError?.call();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _clock.stop();
    await _subscription?.cancel();
  }
}
