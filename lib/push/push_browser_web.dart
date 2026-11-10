import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'push_browser_types.dart';

@JS('paulPush')
external _Bridge? get _bridge;
extension type _Bridge(JSObject _) implements JSObject {
  external JSPromise<JSString> inspect();
  external JSPromise<JSString> permission();
  external JSPromise<JSAny?> identity(JSString? userId, JSString? sessionId);
  external JSPromise<JSString> prepare(JSString userId, JSString publicKey);
  external JSPromise<JSAny?> commit(
    JSString userId,
    JSString proposedId,
    JSString canonicalId,
  );
  external JSPromise<JSString> clear(JSString userId, JSString sessionId);
  external void listen(JSFunction? callback);
  external JSString takeClick();
}

PushBrowser createPushBrowser() => _WebPush();

class _WebPush implements PushBrowser {
  final _clicks = StreamController<PushClick>.broadcast();
  _WebPush() {
    _bridge?.listen(
      ((JSString json) {
        try {
          final click = PushClick.parse(jsonDecode(json.toDart));
          if (click != null && !_clicks.isClosed) _clicks.add(click);
        } catch (_) {
          /* Ignore malformed, untrusted worker messages. */
        }
      }).toJS,
    );
  }
  @override
  Stream<PushClick> get clicks => _clicks.stream;
  @override
  PushClick? takeClick() {
    try {
      return PushClick.parse(jsonDecode(_bridge?.takeClick().toDart ?? 'null'));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> identity(String? userId, String? sessionId) async {
    await _bridge?.identity(userId?.toJS, sessionId?.toJS).toDart;
  }

  @override
  Future<BrowserPushState> inspect() async {
    final bridge = _bridge;
    if (bridge == null) {
      return const BrowserPushState(
        supported: false,
        permission: 'unsupported',
      );
    }
    final data = jsonDecode((await bridge.inspect().toDart).toDart) as Map;
    final binding = data['binding'] as Map?;
    return BrowserPushState(
      supported: data['supported'] == true,
      permission: data['permission'] as String,
      bindingId: binding?['binding_id'] as String?,
      active: binding?['active'] == true,
      storageFull: binding?['storage_full'] == true,
    );
  }

  @override
  Future<String> permission() async =>
      (await _bridge!.permission().toDart).toDart;
  @override
  Future<PreparedPush> prepare(String userId, String publicKey) async {
    final data =
        jsonDecode(
              (await _bridge!.prepare(userId.toJS, publicKey.toJS).toDart)
                  .toDart,
            )
            as Map;
    return PreparedPush(
      data['binding_id'] as String,
      Map<String, dynamic>.from(data['subscription'] as Map),
    );
  }

  @override
  Future<void> commit(
    String userId,
    String proposedId,
    String canonicalId,
  ) async {
    await _bridge!
        .commit(userId.toJS, proposedId.toJS, canonicalId.toJS)
        .toDart;
  }

  @override
  Future<String?> clear(String userId, String sessionId) async {
    final data = jsonDecode(
      (await _bridge?.clear(userId.toJS, sessionId.toJS).toDart)?.toDart ??
          'null',
    );
    return data is Map ? data['binding_id'] as String? : null;
  }

  @override
  void dispose() {
    _bridge?.listen(null);
    unawaited(_clicks.close());
  }
}
