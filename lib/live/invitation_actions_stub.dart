import 'package:flutter/services.dart';

import 'invitation_actions_types.dart';

InvitationActions createInvitationActions() => _FallbackActions();

class _FallbackActions implements InvitationActions {
  @override
  bool get canShare => false;

  @override
  Future<InvitationActionResult> copy(String message) async {
    try {
      await Clipboard.setData(ClipboardData(text: message));
      return InvitationActionResult.completed;
    } catch (_) {
      return InvitationActionResult.failed;
    }
  }

  @override
  Future<InvitationActionResult> share(String message) async =>
      InvitationActionResult.unavailable;
}
