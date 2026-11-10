import 'push_browser_types.dart';

PushBrowser createPushBrowser() => _UnsupportedPush();

class _UnsupportedPush implements PushBrowser {
  @override
  Stream<PushClick> get clicks => const Stream.empty();
  @override
  PushClick? takeClick() => null;
  @override
  Future<void> identity(String? userId, String? sessionId) async {}
  @override
  Future<BrowserPushState> inspect() async =>
      const BrowserPushState(supported: false, permission: 'unsupported');
  @override
  Future<String> permission() async => 'unsupported';
  @override
  Future<PreparedPush> prepare(String userId, String publicKey) async =>
      throw UnsupportedError('Web Push requires a supported browser.');
  @override
  Future<void> commit(
    String userId,
    String proposedId,
    String canonicalId,
  ) async {}
  @override
  Future<String?> clear(String userId, String sessionId) async => null;
  @override
  void dispose() {}
}
