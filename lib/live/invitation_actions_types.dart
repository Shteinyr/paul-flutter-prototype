enum InvitationActionResult {
  completed,
  cancelled,
  unavailable,
  denied,
  failed,
}

abstract interface class InvitationActions {
  bool get canShare;
  Future<InvitationActionResult> copy(String message);
  Future<InvitationActionResult> share(String message);
}
