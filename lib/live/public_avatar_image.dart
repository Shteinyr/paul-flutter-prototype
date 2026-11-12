import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;

/// Shared decode width for both the 65px list and 144px profile avatar.
/// Render at the desired widget size; do not add another per-widget ResizeImage.
const publicAvatarDecodeWidth = 432;

ImageProvider publicAvatarImage(String url, {double scale = 1}) => ResizeImage(
  PublicAvatarImage(url, scale: scale),
  width: publicAvatarDecodeWidth,
);

/// Uses Flutter's bounded decoded-image cache, never a cache of signed URLs.
/// A new provider keeps its own current transport URL even when its key matches
/// an earlier signature. Unknown object names retain the complete URL as key.
@immutable
class PublicAvatarImage extends ImageProvider<PublicAvatarImageKey> {
  const PublicAvatarImage(this.url, {this.scale = 1}) : assert(scale > 0);

  final String url;
  final double scale;

  @override
  Future<PublicAvatarImageKey> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(PublicAvatarImageKey._(_identity(url), scale));

  @override
  ImageStreamCompleter loadImage(
    PublicAvatarImageKey key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _load(key, decode),
    scale: scale,
    debugLabel: 'Public avatar',
  );

  Future<ui.Codec> _load(
    PublicAvatarImageKey key,
    ImageDecoderCallback decode,
  ) async {
    final client = http.Client();
    try {
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 25));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw const PublicAvatarImageLoadException();
      }
      return await decode(
        await ui.ImmutableBuffer.fromUint8List(response.bodyBytes),
      );
    } catch (_) {
      // Like NetworkImage, allow the cache to register the key before eviction.
      // ResizeImage adds the equivalent listener for its outer sized key.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      // Transport and decoder errors can contain the signed URL. Keep them out
      // of framework diagnostics, including when Image has no errorBuilder.
      throw const PublicAvatarImageLoadException();
    } finally {
      client.close();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PublicAvatarImage && other.url == url && other.scale == scale;

  @override
  int get hashCode => Object.hash(url, scale);

  @override
  String toString() => 'PublicAvatarImage(scale: $scale)';
}

@immutable
class PublicAvatarImageKey {
  const PublicAvatarImageKey._(this._identity, this.scale);
  final String _identity;
  final double scale;

  @override
  bool operator ==(Object other) =>
      other is PublicAvatarImageKey &&
      other._identity == _identity &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(_identity, scale);

  @override
  String toString() => 'PublicAvatarImageKey(scale: $scale)';
}

class PublicAvatarImageLoadException implements Exception {
  const PublicAvatarImageLoadException();
  @override
  String toString() => 'Could not load the public avatar.';
}

final _owner = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _version = RegExp(r'^[0-9a-f]{64}\.png$');

String _identity(String url) {
  if (url.contains('%')) return 'url:$url';
  try {
    final uri = Uri.parse(url);
    final segments = uri.pathSegments;
    final query = uri.queryParametersAll;
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasFragment &&
        segments.length == 7 &&
        segments.take(5).join('/') == 'storage/v1/object/sign/avatars' &&
        _owner.hasMatch(segments[5]) &&
        _version.hasMatch(segments[6]) &&
        uri.path == '/${segments.join('/')}' &&
        query.length == 1 &&
        query['token']?.length == 1 &&
        query['token']!.single.isNotEmpty) {
      return 'versioned:${uri.origin}${uri.path}';
    }
  } on FormatException {
    // An unrecognized URL must never inherit another object's cache entry.
  }
  return 'url:$url';
}
