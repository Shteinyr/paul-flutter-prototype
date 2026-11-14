import 'dart:js_interop';

@JS('paulPublicPreviewBootstrap')
external _PreviewBootstrap? get _bridge;

extension type _PreviewBootstrap(JSObject _) implements JSObject {
  external JSPromise<JSString> take(JSString endpoint, JSString key);
}

Future<String?> takePublicPreviewBootstrap(Uri url, String key) async {
  try {
    final bridge = _bridge;
    if (bridge == null) return null;
    return (await bridge
            .take(
              url.resolve('/functions/v1/public-preview').toString().toJS,
              key.toJS,
            )
            .toDart
            .timeout(const Duration(seconds: 2)))
        .toDart;
  } catch (_) {
    return null;
  }
}
