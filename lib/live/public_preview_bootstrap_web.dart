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
            .timeout(const Duration(seconds: 22)))
        .toDart;
  } catch (_) {
    // A request already started in this bridge must not be duplicated while it
    // is slow, nor followed by a second full timeout after a transport failure.
    return '{"__paul_bootstrap_failed":true}';
  }
}
