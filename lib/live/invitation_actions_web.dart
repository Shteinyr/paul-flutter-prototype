import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'invitation_actions_types.dart';

InvitationActions createInvitationActions() => _BrowserActions();

class _BrowserActions implements InvitationActions {
  @override
  bool get canShare =>
      web.window.isSecureContext && web.window.navigator.has('share');

  @override
  Future<InvitationActionResult> copy(String message) async {
    if (!web.window.isSecureContext || !web.window.navigator.has('clipboard')) {
      return InvitationActionResult.unavailable;
    }
    try {
      await web.window.navigator.clipboard.writeText(message).toDart;
      return InvitationActionResult.completed;
    } catch (error) {
      return _failure(error);
    }
  }

  @override
  Future<InvitationActionResult> share(String message) async {
    if (!canShare) return InvitationActionResult.unavailable;
    try {
      // Invoke before the first await to preserve transient user activation.
      await web.window.navigator
          .share(web.ShareData(title: 'Paul invitation', text: message))
          .toDart;
      return InvitationActionResult.completed;
    } catch (error) {
      return _failure(error);
    }
  }
}

InvitationActionResult _failure(Object error) {
  try {
    final name = (error as JSObject)
        .getProperty<JSString?>('name'.toJS)
        ?.toDart;
    if (name == 'AbortError') return InvitationActionResult.cancelled;
    if (name == 'NotAllowedError' || name == 'SecurityError') {
      return InvitationActionResult.denied;
    }
  } catch (_) {
    // Unknown browser errors retain the manual invitation path.
  }
  return InvitationActionResult.failed;
}
