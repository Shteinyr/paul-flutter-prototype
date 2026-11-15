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
  const InvitationContact({required this.name, required this.phones});
  final String name;
  final List<String> phones;
}

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
