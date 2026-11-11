import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/contacts/phone_discovery_api.dart';
import 'package:paul_demo/contacts/phone_discovery_controller.dart';
import 'package:paul_demo/live/invitation_actions.dart';

import 'deletion_controller_test.dart' show actor, other;

PhoneDiscoveryStatus phoneStatus({
  bool verified = true,
  bool enabled = false,
  String? consent,
}) => PhoneDiscoveryStatus(
  verified: verified,
  discoverable: enabled,
  last4: verified ? '0123' : null,
  phoneRevision: verified ? List.filled(64, 'a').join() : null,
  consentRevision: consent,
);

class PhoneRepo implements PhoneDiscoveryRepository {
  @override
  String userId = actor;
  @override
  String? currentUserId = actor;
  final identities = StreamController<String?>.broadcast(sync: true);
  PhoneDiscoveryStatus value = phoneStatus();
  bool sms = true;
  bool disposed = false;
  int codes = 0;
  int verifications = 0;
  int statusCalls = 0;
  bool verifiedResult = true;
  final consents = <(bool, PhoneDiscoveryStatus)>[];
  final lookups = <(List<String>, String?)>[];
  Future<PhoneDiscoveryStatus> Function(bool, PhoneDiscoveryStatus)? consenting;
  Future<PhoneLookup> Function()? looking;
  @override
  Stream<String?> get identityChanges => identities.stream;
  @override
  Future<PhoneDiscoveryStatus> status() async {
    statusCalls++;
    return value;
  }

  @override
  Future<bool> smsEnabled() async => sms;
  @override
  Future<void> requestCode(String phone) async {
    codes++;
  }

  @override
  Future<bool> verifyCode(String phone, String code) async {
    verifications++;
    return verifiedResult;
  }

  @override
  Future<PhoneDiscoveryStatus> consent(
    bool enabled,
    PhoneDiscoveryStatus expected,
  ) async {
    consents.add((enabled, expected));
    if (consenting != null) return consenting!(enabled, expected);
    return value = phoneStatus(enabled: enabled, consent: other);
  }

  @override
  Future<PhoneLookup> lookup(List<String> phones, String? country) async {
    lookups.add((List.of(phones), country));
    return looking == null ? const PhoneLookup({0: other}, {}) : looking!();
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(identities.close());
  }
}

class DiscoveryActions extends Fake implements InvitationActions {
  @override
  bool canPickContacts = true;
  int selections = 0;
  InvitationContactSelection selection = const InvitationContactSelection(
    InvitationActionResult.cancelled,
  );
  Completer<InvitationContactSelection>? pending;
  @override
  Future<InvitationContactSelection> pickContacts() {
    selections++;
    return pending?.future ?? Future.value(selection);
  }
}

void main() {
  late PhoneRepo repo;
  late DiscoveryActions actions;
  late PhoneDiscoveryController controller;
  setUp(() {
    repo = PhoneRepo();
    actions = DiscoveryActions();
    controller = PhoneDiscoveryController(repo, actions);
  });
  tearDown(() => controller.dispose());

  test(
    'opening discovery reads settings without consent, SMS or contact upload',
    () async {
      await controller.refresh();
      expect(controller.status?.verified, isTrue);
      expect(repo.consents, isEmpty);
      expect(repo.codes, 0);
      expect(repo.lookups, isEmpty);
      expect(actions.selections, 0);
    },
  );

  test(
    'explicit picker selection stays local until Find and uploads only checked numbers',
    () async {
      actions.selection = const InvitationContactSelection(
        InvitationActionResult.completed,
        [
          InvitationContact(name: 'First', phones: ['+12025550123']),
          InvitationContact(name: 'Second', phones: ['+12025550124']),
        ],
      );
      await controller.pickContacts();
      expect(repo.lookups, isEmpty);
      expect(controller.contacts, hasLength(2));
      controller.select(controller.contacts.last, false);
      await controller.find('us');
      expect(repo.lookups.single.$1, ['+12025550123']);
      expect(repo.lookups.single.$2, 'US');
      expect(controller.results.single.name, 'First');
      expect(controller.lookup?.matches, {0: other});
      controller.clearContacts();
      expect(controller.contacts, isEmpty);
      expect(controller.results, isEmpty);
    },
  );

  test(
    'picker cancellation and denial preserve a manual fallback without upload',
    () async {
      controller.addNumber('+12025550123');
      await controller.pickContacts();
      expect(controller.contacts, hasLength(1));
      actions.selection = const InvitationContactSelection(
        InvitationActionResult.denied,
      );
      await controller.pickContacts();
      expect(controller.notice, contains('Add the numbers'));
      expect(repo.lookups, isEmpty);
    },
  );

  test(
    'stale consent refreshes the revision without automatic mutation replay',
    () async {
      await controller.refresh();
      repo.consenting = (_, _) async {
        repo.value = phoneStatus(consent: other);
        throw const PhoneDiscoveryException('discovery_state_changed');
      };
      await controller.setConsent(true);
      expect(repo.consents, hasLength(1));
      expect(controller.status?.consentRevision, other);
      expect(controller.error, contains('Review the latest settings'));
      repo.consenting = null;
      await controller.setConsent(false);
      expect(repo.consents.last.$2.consentRevision, other);
    },
  );

  test(
    'lost consent acknowledgement reads committed state before another user choice',
    () async {
      await controller.refresh();
      repo.consenting = (_, _) async {
        repo.value = phoneStatus(enabled: true, consent: other);
        throw StateError('Lost acknowledgement');
      };
      await controller.setConsent(true);
      expect(repo.consents, hasLength(1));
      expect(controller.status?.discoverable, isTrue);
    },
  );

  test(
    'late picker after account switch exposes no selected names or phones',
    () async {
      final gate = Completer<InvitationContactSelection>();
      actions.pending = gate;
      final picking = controller.pickContacts();
      repo.currentUserId = other;
      repo.identities.add(other);
      gate.complete(
        const InvitationContactSelection(InvitationActionResult.completed, [
          InvitationContact(name: 'Private name', phones: ['+12025550123']),
        ]),
      );
      await picking;
      expect(controller.contacts, isEmpty);
      expect(controller.current, isFalse);
    },
  );

  test(
    'late lookup after logout clears selected contacts and ignores results',
    () async {
      final gate = Completer<PhoneLookup>();
      repo.looking = () => gate.future;
      controller.addNumber('+12025550123');
      final finding = controller.find('');
      repo.currentUserId = null;
      repo.identities.add(null);
      gate.complete(const PhoneLookup({0: other}, {}));
      await finding;
      expect(controller.contacts, isEmpty);
      expect(controller.results, isEmpty);
      expect(controller.lookup, isNull);
    },
  );

  test('more than fifty checked numbers never reach lookup', () async {
    for (var n = 0; n < 51; n++) {
      controller.addNumber('+1202555${n.toString().padLeft(4, '0')}');
    }
    await controller.find('');
    expect(repo.lookups, isEmpty);
    controller.select(controller.contacts.last, false);
    await controller.find('');
    expect(repo.lookups.single.$1, hasLength(50));
  });

  test(
    'phone code flow keeps a second confirmation pending and refreshes consent after success',
    () async {
      repo.value = phoneStatus(verified: false);
      await controller.refresh();
      await controller.requestCode('+12025550123');
      repo.verifiedResult = false;
      await controller.verify('123456');
      expect(controller.pendingPhone, '+12025550123');
      repo.verifiedResult = true;
      repo.value = phoneStatus();
      await controller.verify('654321');
      expect(controller.pendingPhone, isNull);
      expect(controller.status?.verified, isTrue);
      expect(controller.status?.discoverable, isFalse);
      expect(repo.consents, isEmpty);
    },
  );
}
