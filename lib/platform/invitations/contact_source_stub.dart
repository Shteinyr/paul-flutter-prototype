import '../../live/invitation_actions_types.dart';

InvitationContactSource createInvitationContactSource() =>
    const UnavailableInvitationContactSource();

class UnavailableInvitationContactSource implements InvitationContactSource {
  const UnavailableInvitationContactSource();
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<InvitationContacts> load({bool requestPermission = false}) async =>
      const InvitationContacts(InvitationContactAccess.unavailable);
  @override
  Future<void> openSettings() async {}
}
