import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';

typedef PickProfilePhoto = Future<Uint8List?> Function();

Future<Uint8List?> pickProfilePhoto() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 1024,
    maxHeight: 1024,
    imageQuality: 85,
    requestFullMetadata: false,
  );
  if (file == null) return null;
  // Bound memory and local storage use before decoding untrusted image bytes.
  if (await file.length() > 3 * 1024 * 1024) {
    throw const PhotoSelectionException('Choose an image smaller than 3 MB.');
  }
  final bytes = await file.readAsBytes();
  return normalizeProfilePhoto(bytes);
}

Future<Uint8List> normalizeProfilePhoto(
  Uint8List bytes, {
  int targetWidth = 768,
}) async {
  try {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final encoded = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (encoded == null || encoded.lengthInBytes > 3 * 1024 * 1024) {
          throw const PhotoSelectionException('Choose a smaller image.');
        }
        return encoded.buffer.asUint8List();
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } on PhotoSelectionException {
    rethrow;
  } catch (_) {
    throw const PhotoSelectionException('This image could not be opened.');
  }
}

class PhotoSelectionException implements Exception {
  const PhotoSelectionException(this.message);
  final String message;
}
