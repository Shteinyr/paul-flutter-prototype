import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paul_demo/live/invitation_actions.dart';
import 'package:paul_demo/live/invitation_controller.dart';
import 'package:paul_demo/live/live_connect_view.dart';

class _Issuer implements InvitationIssuer {
  int issued = 0;
  bool failing = false;

  @override
  Future<LiveInvitation> issue(String token) async {
    if (failing) throw StateError('offline');
    issued++;
    return LiveInvitation(
      id: '$issued',
      token: token,
      code: 'code-$issued',
      expiresAt: DateTime.utc(2030),
      lifetime: const Duration(minutes: 15),
    );
  }

  @override
  Future<void> revoke(String id) async {}
}

class _Actions implements InvitationActions {
  @override
  bool canShare = true;
  @override
  bool canPickContacts = false;
  InvitationContactSelection selection = const InvitationContactSelection(
    InvitationActionResult.cancelled,
  );
  final smsNumbers = <String>[];
  final smsMessages = <String?>[];
  Completer<InvitationContactSelection>? pendingSelection;

  @override
  Future<InvitationContactSelection> pickContacts() =>
      pendingSelection?.future ?? Future.value(selection);

  @override
  Future<InvitationActionResult> openSms(
    String number, {
    String? message,
  }) async {
    smsNumbers.add(number);
    smsMessages.add(message);
    return pending == null ? result : await pending!.future;
  }

  final copies = <String>[];
  final shares = <String>[];
  InvitationActionResult result = InvitationActionResult.completed;
  Completer<InvitationActionResult>? pending;

  @override
  Future<InvitationActionResult> copy(String message) {
    copies.add(message);
    return pending?.future ?? Future.value(result);
  }

  @override
  Future<InvitationActionResult> share(String message) {
    shares.add(message);
    return pending?.future ?? Future.value(result);
  }
}

class _Contacts implements InvitationContactSource {
  _Contacts(this.value);
  InvitationContacts value;
  final events = StreamController<void>.broadcast(sync: true);
  final requests = <bool>[];
  Future<InvitationContacts> Function(bool)? read;
  int settings = 0;
  @override
  Stream<void> get changes => events.stream;
  @override
  Future<InvitationContacts> load({bool requestPermission = false}) {
    requests.add(requestPermission);
    return read?.call(requestPermission) ?? Future.value(value);
  }

  @override
  Future<void> openSettings() async {
    settings++;
  }
}

const _one = InvitationContact(
  id: 'one',
  name: 'One contact',
  phones: ['+12025550100'],
);
const _many = InvitationContact(
  id: 'many',
  name: 'Several numbers',
  phones: ['+1 (202) 555-0100', '+1 202 555 0100', '+12025550101'],
);
const _noNumber = InvitationContact(
  id: 'empty',
  name: 'No number contact',
  phones: [],
);

Future<void> _open(
  WidgetTester tester,
  InvitationController controller,
  _Actions actions, {
  InvitationContactSource? contacts,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LiveConnectView(
        invitation: controller,
        appUrl: Uri.parse('https://paul.example/'),
        actions: actions,
        contacts: contacts,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'copy confirms completion and native share receives current credentials',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Open the invitation in your browser.'), findsNothing);
      await tester.tap(find.byKey(const Key('copy-live-invitation')));
      await tester.pumpAndSettle();
      expect(find.text('Invitation copied.'), findsOneWidget);
      expect(
        actions.copies.single,
        contains(
          'https://paul.example/#invite=${controller.invitation!.token}',
        ),
      );
      expect(actions.copies.single, contains('code-1'));
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      expect(actions.shares, hasLength(1));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Confirm delivery in the receiving app.'),
        findsOneWidget,
      );
      controller.dispose();
    },
  );

  testWidgets('copy failure and retry preserve manual text', (tester) async {
    final controller = InvitationController(_Issuer());
    await controller.refresh();
    final actions = _Actions()..result = InvitationActionResult.denied;
    await _open(tester, controller, actions);
    await tester.tap(find.byKey(const Key('copy-live-invitation')));
    await tester.pumpAndSettle();
    expect(find.textContaining('action was blocked'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
    actions.result = InvitationActionResult.completed;
    await tester.tap(find.byKey(const Key('copy-live-invitation')));
    await tester.pumpAndSettle();
    expect(find.text('Invitation copied.'), findsOneWidget);
    expect(actions.copies, hasLength(2));
    controller.dispose();
  });

  testWidgets('unsupported browser and cancellation retain copy path', (
    tester,
  ) async {
    final controller = InvitationController(_Issuer());
    await controller.refresh();
    final actions = _Actions()..canShare = false;
    await _open(tester, controller, actions);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('share-live-invitation')))
          .onPressed,
      isNull,
    );
    expect(
      find.textContaining('System sharing is unavailable'),
      findsOneWidget,
    );
    actions.canShare = true;
    actions.result = InvitationActionResult.cancelled;
    await _open(tester, controller, actions);
    await tester.tap(find.byKey(const Key('share-live-invitation')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Sharing cancelled.'), findsOneWidget);
    expect(find.byKey(const Key('copy-live-invitation')), findsOneWidget);
    controller.dispose();
  });

  testWidgets(
    'direct system action blocks repeats and ignores completion after leaving',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final actions = _Actions()..pending = Completer();
      await _open(tester, controller, actions);
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      expect(actions.shares, hasLength(1));
      await tester.pumpWidget(const MaterialApp(home: Text('Other screen')));
      await tester.pumpAndSettle();
      actions.pending!.complete(InvitationActionResult.completed);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Other screen'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets('Connect follows renewal and stale share requires a fresh tap', (
    tester,
  ) async {
    var elapsed = Duration.zero;
    final issuer = _Issuer();
    final controller = InvitationController(issuer, elapsed: () => elapsed);
    await controller.refresh();
    final actions = _Actions()..pending = Completer();
    await _open(tester, controller, actions);
    await tester.tap(find.byKey(const Key('share-live-invitation')));
    await tester.pump();
    elapsed = const Duration(minutes: 15);
    actions.pending!.complete(InvitationActionResult.completed);
    await tester.pumpAndSettle();
    expect(issuer.issued, 2);
    expect(find.textContaining('Use invite code: code-2'), findsWidgets);
    expect(find.textContaining('invitation changed'), findsOneWidget);
    expect(actions.shares, hasLength(1));
    expect(find.textContaining('Share request completed'), findsNothing);
    actions.pending = null;
    await tester.tap(find.byKey(const Key('share-live-invitation')));
    await tester.pumpAndSettle();
    expect(actions.shares.last, contains('code-2'));
    controller.dispose();
  });

  testWidgets(
    'renewal failure hides old credentials and allows explicit retry',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed);
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      elapsed = const Duration(minutes: 15);
      issuer.failing = true;
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('Retry invitation'), findsOneWidget);
      issuer.failing = false;
      await tester.tap(find.text('Retry invitation'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use invite code: code-2'), findsWidgets);
      expect(actions.shares, isEmpty);
      controller.dispose();
    },
  );

  test('personal SMS URI accepts a single safe number only', () {
    expect(invitationSmsNumber('+1 (202) 555-0100'), '+12025550100');
    expect(invitationSmsNumber('020 555.0100'), '0205550100');
    for (final raw in [
      '+12025550100?body=x',
      '123,456',
      '123;456',
      '123\n456',
      'sms:123',
      '123#456',
      '+123 ext 4',
      '12',
      '++123',
      '1234567890123456',
    ]) {
      expect(invitationSmsNumber(raw), isNull, reason: raw);
    }
  });

  testWidgets(
    'Connect requests access on entry and renders one Invite per person',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.granted, [
          _one,
          _many,
          _noNumber,
        ]),
      );
      addTearDown(source.events.close);
      final actions = _Actions();
      await _open(tester, controller, actions, contacts: source);
      expect(source.requests, [true]);
      expect(find.text('Invite'), findsNWidgets(3));
      expect(find.byKey(const Key('pick-invitation-contacts')), findsNothing);
      final noNumber = find.descendant(
        of: find.byKey(const ValueKey('invitation-contact-empty')),
        matching: find.byType(TextButton),
      );
      expect(tester.widget<TextButton>(noNumber).onPressed, isNull);
      final one = find.descendant(
        of: find.byKey(const ValueKey('invitation-contact-one')),
        matching: find.byType(TextButton),
      );
      await tester.tap(one);
      await tester.pumpAndSettle();
      expect(actions.smsNumbers, ['+12025550100']);
      expect(actions.smsMessages.single, contains('code-1'));
      expect(actions.copies, isEmpty);
      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.textContaining('Requested SMS app'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets(
    'multiple numbers require one explicit choice and cancellation sends nothing',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.granted, [_many]),
      );
      addTearDown(source.events.close);
      final actions = _Actions();
      await _open(tester, controller, actions, contacts: source);
      expect(find.text('Invite'), findsOneWidget);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(
        find.text('+12025550100'),
        findsOneWidget,
      ); // Formatting duplicates are merged.
      expect(actions.smsNumbers, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(actions.smsNumbers, isEmpty);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+12025550101'));
      await tester.pumpAndSettle();
      expect(actions.smsNumbers, ['+12025550101']);
      expect(
        actions.smsMessages.single,
        contains('#invite=${controller.invitation!.token}'),
      );
      expect(find.text('Invite'), findsOneWidget);
      controller.dispose();
    },
  );

  for (final access in [
    InvitationContactAccess.denied,
    InvitationContactAccess.permanentlyDenied,
    InvitationContactAccess.restricted,
    InvitationContactAccess.unavailable,
  ]) {
    testWidgets(
      '$access leaves Share and copy usable without exposing old contact data',
      (tester) async {
        final controller = InvitationController(_Issuer());
        await controller.refresh();
        final source = _Contacts(InvitationContacts(access, const [_one]));
        addTearDown(source.events.close);
        final actions = _Actions();
        await _open(tester, controller, actions, contacts: source);
        expect(find.text('One contact'), findsNothing);
        expect(find.text('Invite'), findsNothing);
        await tester.tap(find.byKey(const Key('copy-live-invitation')));
        await tester.pumpAndSettle();
        expect(actions.copies, hasLength(1));
        await tester.tap(find.byKey(const Key('share-live-invitation')));
        await tester.pumpAndSettle();
        expect(actions.shares, hasLength(1));
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(source.requests, [true, false]);
        controller.dispose();
      },
    );
  }

  testWidgets(
    'limited permission shows its subset and resume loads a changed book without prompting',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.limited, [_one]),
      );
      addTearDown(source.events.close);
      await _open(tester, controller, _Actions(), contacts: source);
      expect(find.text('One contact'), findsOneWidget);
      expect(find.textContaining('Only contacts you allow'), findsOneWidget);
      await tester.tap(find.byKey(const Key('invitation-contact-settings')));
      await tester.pumpAndSettle();
      expect(source.settings, 1);
      source.value = const InvitationContacts(InvitationContactAccess.granted, [
        _many,
      ]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('One contact'), findsNothing);
      expect(find.text('Several numbers'), findsOneWidget);
      expect(source.requests, [true, false]);
      source.value = const InvitationContacts(InvitationContactAccess.denied);
      source.events.add(null);
      await tester.pump(const Duration(milliseconds: 210));
      await tester.pumpAndSettle();
      expect(find.text('Several numbers'), findsNothing);
      expect(find.text('Invite'), findsNothing);
      controller.dispose();
    },
  );

  testWidgets(
    'empty book and failed read have distinct states and retry keeps sharing available',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.granted),
      );
      addTearDown(source.events.close);
      await _open(tester, controller, _Actions(), contacts: source);
      expect(find.text('No contacts available.'), findsOneWidget);
      source.read = (_) =>
          Future.error(StateError('contact provider unavailable'));
      source.events.add(null);
      await tester.pump(const Duration(milliseconds: 210));
      await tester.pumpAndSettle();
      expect(
        find.text('Could not load contacts. Please retry.'),
        findsOneWidget,
      );
      source.read = null;
      source.value = const InvitationContacts(InvitationContactAccess.granted, [
        _one,
      ]);
      await tester.tap(find.byKey(const Key('retry-invitation-contacts')));
      await tester.pumpAndSettle();
      expect(find.text('One contact'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets(
    'contact changes dismiss a stale number selector without opening SMS',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.granted, [_many]),
      );
      addTearDown(source.events.close);
      final actions = _Actions();
      await _open(tester, controller, actions, contacts: source);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      source.value = const InvitationContacts(
        InvitationContactAccess.restricted,
      );
      source.events.add(null);
      await tester.pump(const Duration(milliseconds: 210));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsNothing);
      expect(find.text('Several numbers'), findsNothing);
      expect(actions.smsNumbers, isEmpty);
      controller.dispose();
    },
  );

  testWidgets(
    'permission completion after leaving Connect cannot expose names or launch SMS',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final pending = Completer<InvitationContacts>();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.notDetermined),
      )..read = (_) => pending.future;
      addTearDown(source.events.close);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveConnectView(
            invitation: controller,
            appUrl: Uri.parse('https://paul.example/'),
            actions: _Actions(),
            contacts: source,
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: Text('Other screen')));
      pending.complete(
        const InvitationContacts(InvitationContactAccess.granted, [_one]),
      );
      await tester.pumpAndSettle();
      expect(find.text('One contact'), findsNothing);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'large address book builds lazily and SMS resume preserves the list and scroll',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final rows = List.generate(
        10000,
        (i) => InvitationContact(
          id: 'id-$i',
          name: 'Local person $i',
          phones: ['+12025550100'],
        ),
      );
      final source = _Contacts(
        InvitationContacts(InvitationContactAccess.granted, rows),
      );
      addTearDown(source.events.close);
      final actions = _Actions();
      await _open(tester, controller, actions, contacts: source);
      expect(find.text('Local person 9999'), findsNothing);
      expect(find.text('Invite').evaluate().length, lessThan(40));
      await tester.drag(
        find.byKey(const Key('connect-contacts-list')),
        const Offset(0, -700),
      );
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const Key('connect-contacts-list')),
          )
          .controller!;
      final offset = scroll.offset;
      final visible = find.text('Invite').hitTestable().first;
      await tester.tap(visible);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(actions.smsNumbers, hasLength(1));
      expect(scroll.offset, closeTo(offset, 1));
      expect(find.text('Invite').evaluate().length, lessThan(50));
      expect(source.requests, [true, false]);
      controller.dispose();
    },
  );

  testWidgets(
    'expired invitation renews without opening system share until a fresh tap',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed);
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      elapsed = const Duration(minutes: 15);
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      await tester.pumpAndSettle();
      expect(issuer.issued, 2);
      expect(actions.shares, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const Key('share-live-invitation')));
      await tester.pumpAndSettle();
      expect(actions.shares.single, contains('code-2'));
      controller.dispose();
    },
  );
  testWidgets(
    'source Connect controls fit a narrow mobile screen without an intermediate dialog',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text('Hey, let’s connect in Paul.'), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Copy invitation'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Share'));
      expect(actions.shares, hasLength(1));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
  );
  testWidgets(
    'later rotation retires a completed copy status on the open Connect screen',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final actions = _Actions();
      await _open(tester, controller, actions);
      await tester.tap(find.byKey(const Key('copy-live-invitation')));
      await tester.pumpAndSettle();
      expect(find.text('Invitation copied.'), findsOneWidget);
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Invitation copied.'), findsNothing);
      expect(find.textContaining('invitation changed'), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy-live-invitation')));
      await tester.pumpAndSettle();
      expect(actions.copies.last, contains('code-2'));
      expect(find.text('Invitation copied.'), findsOneWidget);
      controller.dispose();
    },
  );
  testWidgets(
    'permission dialog resume and a burst of book changes coalesce without a second prompt',
    (tester) async {
      final controller = InvitationController(_Issuer());
      await controller.refresh();
      final initial = Completer<InvitationContacts>();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.limited, [_one]),
      );
      source.read = (_) => source.requests.length == 1
          ? initial.future
          : Future.value(source.value);
      addTearDown(source.events.close);
      await tester.pumpWidget(
        MaterialApp(
          home: LiveConnectView(
            invitation: controller,
            appUrl: Uri.parse('https://paul.example/'),
            actions: _Actions(),
            contacts: source,
          ),
        ),
      );
      await tester.pump();
      expect(source.requests, [true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      source.events.add(null);
      source.events.add(null);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(source.requests, [true]);
      initial.complete(
        const InvitationContacts(InvitationContactAccess.granted, [_many]),
      );
      await tester.pumpAndSettle();
      expect(source.requests, [true, false]);
      expect(find.text('Several numbers'), findsNothing);
      expect(find.text('One contact'), findsOneWidget);
      controller.dispose();
    },
  );

  testWidgets(
    'an invitation expiring during number selection renews before SMS and needs a fresh Invite',
    (tester) async {
      var elapsed = Duration.zero;
      final issuer = _Issuer();
      final controller = InvitationController(issuer, elapsed: () => elapsed);
      await controller.refresh();
      final source = _Contacts(
        const InvitationContacts(InvitationContactAccess.granted, [_many]),
      );
      addTearDown(source.events.close);
      final actions = _Actions();
      await _open(tester, controller, actions, contacts: source);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      elapsed = const Duration(minutes: 15);
      await tester.tap(find.text('+12025550101'));
      await tester.pumpAndSettle();
      expect(issuer.issued, 2);
      expect(actions.smsNumbers, isEmpty);
      expect(find.text('Several numbers'), findsOneWidget);
      await tester.tap(find.text('Invite'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('+12025550101'));
      await tester.pumpAndSettle();
      expect(actions.smsMessages.single, contains('code-2'));
      controller.dispose();
    },
  );
}
