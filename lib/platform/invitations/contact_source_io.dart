import 'dart:io';
import 'native_contact_source.dart';
import 'contact_source_stub.dart';
import '../../live/invitation_actions_types.dart';

InvitationContactSource createInvitationContactSource() =>
    Platform.isIOS || Platform.isAndroid
    ? NativeInvitationContactSource()
    : const UnavailableInvitationContactSource();
