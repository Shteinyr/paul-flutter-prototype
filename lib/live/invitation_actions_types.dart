enum InvitationActionResult {
  completed,
  cancelled,
  unavailable,
  denied,
  failed,
}

abstract interface class InvitationActions {
  bool get canShare;
  bool get canPickContacts;
  Future<InvitationContactSelection> pickContacts();
  Future<InvitationActionResult> openSms(String number, {String? message});
  Future<InvitationActionResult> copy(String message);
  Future<InvitationActionResult> share(String message);
}

class InvitationContact {
  const InvitationContact({
    this.id = '',
    required this.name,
    required this.phones,
  });
  final String id;
  final String name;
  final List<String> phones;
}

enum InvitationContactAccess {
  notDetermined,
  granted,
  limited,
  denied,
  permanentlyDenied,
  restricted,
  unavailable,
  failed,
}

class InvitationContacts {
  const InvitationContacts(this.access, [this.contacts = const []]);
  final InvitationContactAccess access;
  final List<InvitationContact> contacts;
  bool get readable =>
      access == InvitationContactAccess.granted ||
      access == InvitationContactAccess.limited;
}

/// Read-only, device-local contacts. No account matching or server transport.
abstract interface class InvitationContactSource {
  Stream<void> get changes;
  Future<InvitationContacts> load({bool requestPermission = false});
  Future<void> openSettings();
}

List<String> invitationContactNumbers(InvitationContact contact) => [
  ...{
    for (final phone in contact.phones)
      if (invitationSmsNumber(phone) case final String number) number,
  },
];

class InvitationContactSelection {
  const InvitationContactSelection(this.result, [this.contacts = const []]);
  final InvitationActionResult result;
  final List<InvitationContact> contacts;
}

/// A single local or international number. No country is inferred.
String? invitationSmsNumber(String raw) {
  if (!RegExp(r'^\+?[0-9 ().-]+$').hasMatch(raw)) return null;
  final number = raw.replaceAll(RegExp(r'[ ().-]'), '');
  if (!RegExp(r'^\+?[0-9]{3,15}$').hasMatch(number)) return null;
  return number;
}
