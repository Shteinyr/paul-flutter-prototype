import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../live/invitation_actions_types.dart';
import 'native_contact_source.dart';

/// Platform operations stay behind the P05 interface. Contact data stays local;
/// production reads use only read permission and the accessible address book.
class NativeInvitationActions implements InvitationActions {
  NativeInvitationActions({
    Future<ShareResult> Function(String)? shareText,
    Future<InvitationContact?> Function()? selectContact,
    InvitationContactSource? contactSource,
    Future<bool> Function(Uri)? launchSms,
    Future<void> Function(String)? copyText,
    Rect? Function()? shareOrigin,
  }) : _share =
           shareText ??
           ((text) => SharePlus.instance.share(
             ShareParams(
               text: text,
               title: 'Paul',
               sharePositionOrigin: shareOrigin?.call(),
             ),
           )),
       _select = selectContact,
       _contacts = contactSource ?? NativeInvitationContactSource(),
       _launch =
           launchSms ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication)),
       _copy =
           copyText ?? ((text) => Clipboard.setData(ClipboardData(text: text)));

  final Future<ShareResult> Function(String) _share;
  final Future<InvitationContact?> Function()? _select;
  final InvitationContactSource _contacts;
  final Future<bool> Function(Uri) _launch;
  final Future<void> Function(String) _copy;
  bool _selecting = false;
  bool _sharing = false;
  @override
  bool get canShare => true;
  @override
  bool get canPickContacts => true;

  @override
  Future<InvitationContactSelection> pickContacts() async {
    if (_selecting) {
      return const InvitationContactSelection(InvitationActionResult.cancelled);
    }
    _selecting = true;
    try {
      final select = _select;
      if (select != null) {
        final contact = await select();
        return contact == null
            ? const InvitationContactSelection(InvitationActionResult.cancelled)
            : InvitationContactSelection(InvitationActionResult.completed, [
                contact,
              ]);
      }
      final result = await _contacts.load(requestPermission: true);
      return InvitationContactSelection(switch (result.access) {
        InvitationContactAccess.granted ||
        InvitationContactAccess.limited => InvitationActionResult.completed,
        InvitationContactAccess.unavailable =>
          InvitationActionResult.unavailable,
        InvitationContactAccess.failed => InvitationActionResult.failed,
        _ => InvitationActionResult.denied,
      }, result.contacts);
    } catch (error) {
      return InvitationContactSelection(_failure(error));
    } finally {
      _selecting = false;
    }
  }

  @override
  Future<InvitationActionResult> openSms(
    String number, {
    String? message,
  }) async {
    final safe = invitationSmsNumber(number);
    if (safe == null) return InvitationActionResult.failed;
    try {
      return await _launch(
            Uri(
              scheme: 'sms',
              path: safe,
              query: message == null
                  ? null
                  : 'body=${Uri.encodeComponent(message)}',
            ),
          )
          ? InvitationActionResult.completed
          : InvitationActionResult.unavailable;
    } catch (error) {
      return _failure(error);
    }
  }

  @override
  Future<InvitationActionResult> copy(String message) async {
    try {
      await _copy(message);
      return InvitationActionResult.completed;
    } catch (error) {
      return _failure(error);
    }
  }

  @override
  Future<InvitationActionResult> share(String message) async {
    if (_sharing) return InvitationActionResult.cancelled;
    _sharing = true;
    try {
      final result = await _share(message);
      return switch (result.status) {
        ShareResultStatus.success => InvitationActionResult.completed,
        ShareResultStatus.dismissed => InvitationActionResult.cancelled,
        // This status means the sheet opened but the OS cannot report its result.
        ShareResultStatus.unavailable => InvitationActionResult.completed,
      };
    } catch (error) {
      return _failure(error);
    } finally {
      _sharing = false;
    }
  }

  InvitationActionResult _failure(Object error) {
    if (error is MissingPluginException) {
      return InvitationActionResult.unavailable;
    }
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      if (code.contains('permission') ||
          code.contains('denied') ||
          code.contains('restricted')) {
        return InvitationActionResult.denied;
      }
      if (code.contains('cancel')) return InvitationActionResult.cancelled;
      if (code.contains('unavailable') || code == 'not_available') {
        return InvitationActionResult.unavailable;
      }
    }
    return InvitationActionResult.failed;
  }
}
