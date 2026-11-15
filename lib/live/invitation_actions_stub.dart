import 'dart:io';
import 'package:flutter/services.dart';
import '../platform/invitations/native_invitation_actions.dart';

import 'invitation_actions_types.dart';

InvitationActions createInvitationActions() =>
    Platform.isIOS || Platform.isAndroid
    ? NativeInvitationActions()
    : _FallbackActions();

class _FallbackActions implements InvitationActions {
  @override
  bool get canPickContacts => false;

  @override
  Future<InvitationContactSelection> pickContacts() async =>
      const InvitationContactSelection(InvitationActionResult.unavailable);

  @override
  Future<InvitationActionResult> openSms(String number) async =>
      InvitationActionResult.unavailable;

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
