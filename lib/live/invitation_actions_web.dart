import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'invitation_actions_types.dart';

InvitationActions createInvitationActions() => _BrowserActions();

class _BrowserActions implements InvitationActions {
  @override
  bool get canPickContacts =>
      web.window.isSecureContext &&
      web.window.top == web.window &&
      web.window.navigator
              .getProperty<JSObject?>('contacts'.toJS)
              ?.getProperty<JSAny?>('select'.toJS)
              ?.isA<JSFunction>() ==
          true;

  @override
  Future<InvitationContactSelection> pickContacts() async {
    if (!canPickContacts) {
      return const InvitationContactSelection(
        InvitationActionResult.unavailable,
      );
    }
    try {
      final manager = _ContactsManager(
        web.window.navigator.getProperty<JSObject>('contacts'.toJS),
      );
      // No async capability query between the gesture and select().
      final selected = await manager
          .select(
            ['name'.toJS, 'tel'.toJS].toJS,
            _ContactOptions(multiple: true),
          )
          .toDart;
      final contacts = selected.toDart.map((value) {
        final contact = _Contact(value);
        return InvitationContact(
          name:
              contact.name?.toDart
                  .map((part) => part.toDart)
                  .join(' ')
                  .trim() ??
              '',
          phones:
              contact.tel?.toDart
                  .map((phone) => phone.toDart)
                  .toSet()
                  .toList() ??
              const [],
        );
      }).toList();
      return InvitationContactSelection(
        contacts.isEmpty
            ? InvitationActionResult.cancelled
            : InvitationActionResult.completed,
        contacts,
      );
    } catch (error) {
      return InvitationContactSelection(_failure(error));
    }
  }

  @override
  Future<InvitationActionResult> openSms(String number) async {
    final safe = invitationSmsNumber(number);
    if (safe == null) return InvitationActionResult.failed;
    try {
      final link = web.HTMLAnchorElement()
        ..href = Uri(scheme: 'sms', path: safe).toString();
      web.document.body?.appendChild(link);
      try {
        link.click();
      } finally {
        link.remove();
      }
      // Browsers cannot confirm whether an external SMS handler exists.
      return InvitationActionResult.completed;
    } catch (_) {
      return InvitationActionResult.failed;
    }
  }

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

extension type _ContactsManager(JSObject _) implements JSObject {
  external JSPromise<JSArray<JSObject>> select(
    JSArray<JSString> properties,
    _ContactOptions options,
  );
}

extension type _ContactOptions._(JSObject _) implements JSObject {
  external factory _ContactOptions({bool multiple});
}

extension type _Contact(JSObject _) implements JSObject {
  external JSArray<JSString>? get name;
  external JSArray<JSString>? get tel;
}
