import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:paul_demo/live/invitation_actions_types.dart';
import 'package:paul_demo/platform/invitations/native_contact_source.dart';
import 'package:paul_demo/platform/invitations/native_invitation_actions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_contacts');
  final calls = <MethodCall>[];
  var status = 'notDetermined';
  var requestedStatus = 'granted';
  var reads = 0;
  var reduceAccessDuringRead = false;
  late NativeInvitationContactSource source;
  setUp(() {
    calls.clear();
    status = 'notDetermined';
    requestedStatus = 'granted';
    reads = 0;
    reduceAccessDuringRead = false;
    source = NativeInvitationContactSource(changes: const Stream.empty());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'permissions.check':
              expect((call.arguments as Map)['type'], 'read');
              return status;
            case 'permissions.request':
              expect((call.arguments as Map)['type'], 'read');
              status = requestedStatus;
              return status;
            case 'crud.getAll':
              reads++;
              expect((call.arguments as Map)['properties'], ['phone']);
              expect((call.arguments as Map).containsKey('limit'), isFalse);
              final full = status == 'granted';
              if (reduceAccessDuringRead && full) status = 'limited';
              return [
                if (full)
                  Contact(
                    id: 'private',
                    displayName: 'Z outside limited access',
                    phones: [Phone(number: '+12025550199')],
                  ).toJson(),
                Contact(
                  id: 'allowed',
                  displayName: 'Allowed',
                  phones: [Phone(number: '+12025550100')],
                ).toJson(),
                if (full)
                  Contact(id: 'no-phone', displayName: 'No phone').toJson(),
              ];
            case 'permissions.openSettings':
              return null;
            default:
              fail('Unexpected native method: ${call.method}');
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'first deliberate read requests only read access then gets every accessible contact without photos',
    () async {
      final result = await source.load(requestPermission: true);
      expect(result.access, InvitationContactAccess.granted);
      expect(result.contacts.map((c) => c.id), [
        'allowed',
        'no-phone',
        'private',
      ]);
      expect(result.contacts.first.phones, ['+12025550100']);
      expect(result.contacts[1].phones, isEmpty);
      expect(
        calls.where((c) => c.method == 'permissions.request'),
        hasLength(1),
      );
      expect(reads, 1);
      expect(() => result.contacts.clear(), throwsUnsupportedError);
      expect(
        () => result.contacts.first.phones.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'passive resume never requests an undetermined or denied permission',
    () async {
      for (final value in [
        'notDetermined',
        'denied',
        'permanentlyDenied',
        'restricted',
      ]) {
        status = value;
        final result = await source.load();
        expect(result.readable, isFalse);
        expect(result.contacts, isEmpty);
      }
      expect(reads, 0);
      expect(calls.where((c) => c.method == 'permissions.request'), isEmpty);
    },
  );

  test(
    'the native action adapter reads the book instead of opening a single-contact picker',
    () async {
      final result = await NativeInvitationActions().pickContacts();
      expect(result.result, InvitationActionResult.completed);
      expect(result.contacts, hasLength(3));
      expect(calls.any((call) => call.method.startsWith('native.')), isFalse);
      expect(reads, 1);
    },
  );

  test(
    'limited access gets only the OS-accessible subset and can open system settings',
    () async {
      requestedStatus = 'limited';
      final result = await source.load(requestPermission: true);
      expect(result.access, InvitationContactAccess.limited);
      expect(result.contacts.map((c) => c.id), ['allowed']);
      await source.openSettings();
      expect(calls.last.method, 'permissions.openSettings');
    },
  );

  test(
    'permanent and restricted access do not re-prompt or read even on explicit retry',
    () async {
      for (final value in ['permanentlyDenied', 'restricted']) {
        status = value;
        expect((await source.load(requestPermission: true)).readable, isFalse);
      }
      expect(reads, 0);
      expect(calls.where((c) => c.method == 'permissions.request'), isEmpty);
    },
  );

  test(
    'permission reduction during fetch discards the full result and rereads the limited subset',
    () async {
      status = 'granted';
      reduceAccessDuringRead = true;
      final result = await source.load();
      expect(result.access, InvitationContactAccess.limited);
      expect(result.contacts.map((c) => c.id), ['allowed']);
      expect(reads, 2);
    },
  );

  test(
    'missing platform plugin maps to unavailable without a contact read',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw MissingPluginException(),
          );
      expect((await source.load()).access, InvitationContactAccess.unavailable);
      expect(reads, 0);
    },
  );

  test(
    'one person can have multiple raw numbers but duplicate formatted numbers invite only once',
    () {
      const person = InvitationContact(
        id: 'one',
        name: 'One',
        phones: [
          '+1 (202) 555-0100',
          '+12025550100',
          '+12025550101',
          '123;456',
        ],
      );
      expect(invitationContactNumbers(person), [
        '+12025550100',
        '+12025550101',
      ]);
    },
  );
}
