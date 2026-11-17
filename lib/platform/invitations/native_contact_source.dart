import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../../live/invitation_actions_types.dart';

class NativeInvitationContactSource implements InvitationContactSource {
  NativeInvitationContactSource({Stream<void>? changes})
    : _changes = changes ?? FlutterContacts.onDatabaseChange;
  final Stream<void> _changes;
  @override
  Stream<void> get changes => _changes;
  @override
  Future<void> openSettings() => FlutterContacts.permissions.openSettings();

  static InvitationContactAccess _access(PermissionStatus status) =>
      switch (status) {
        PermissionStatus.granted => InvitationContactAccess.granted,
        PermissionStatus.limited => InvitationContactAccess.limited,
        PermissionStatus.notDetermined => InvitationContactAccess.notDetermined,
        PermissionStatus.denied => InvitationContactAccess.denied,
        PermissionStatus.permanentlyDenied =>
          InvitationContactAccess.permanentlyDenied,
        PermissionStatus.restricted => InvitationContactAccess.restricted,
      };
  static bool _readable(PermissionStatus status) =>
      status == PermissionStatus.granted || status == PermissionStatus.limited;

  @override
  Future<InvitationContacts> load({bool requestPermission = false}) async {
    try {
      var status = await FlutterContacts.permissions.check(PermissionType.read);
      if (requestPermission &&
          (status == PermissionStatus.notDetermined ||
              status == PermissionStatus.denied)) {
        status = await FlutterContacts.permissions.request(PermissionType.read);
      }
      // If full access becomes limited while fetching, discard that full result
      // and query again under the new permission before exposing any names.
      for (var attempt = 0; attempt < 2; attempt++) {
        if (!_readable(status)) return InvitationContacts(_access(status));
        final rows = await FlutterContacts.getAll(
          properties: {ContactProperty.phone},
        );
        final after = await FlutterContacts.permissions.check(
          PermissionType.read,
        );
        if (after != status) {
          status = after;
          continue;
        }
        final contacts = rows
            .map(
              (contact) => InvitationContact(
                id: contact.id ?? '',
                name: contact.displayName ?? '',
                phones: List.unmodifiable(
                  contact.phones.map((phone) => phone.number),
                ),
              ),
            )
            .toList();
        contacts.sort((a, b) {
          final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          return name == 0 ? a.id.compareTo(b.id) : name;
        });
        return InvitationContacts(_access(status), List.unmodifiable(contacts));
      }
      if (!_readable(status)) return InvitationContacts(_access(status));
      return const InvitationContacts(InvitationContactAccess.failed);
    } on MissingPluginException {
      return const InvitationContacts(InvitationContactAccess.unavailable);
    } on PlatformException catch (error) {
      final code = error.code.toLowerCase();
      return InvitationContacts(
        code.contains('permission') || code.contains('denied')
            ? InvitationContactAccess.denied
            : InvitationContactAccess.failed,
      );
    }
  }
}
