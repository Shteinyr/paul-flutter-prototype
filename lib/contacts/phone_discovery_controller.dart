import 'dart:async';

import 'package:flutter/foundation.dart';

import '../live/invitation_actions.dart';
import 'phone_discovery_api.dart';

class DiscoveryContact {
  DiscoveryContact(this.name, this.phone);
  final String name;
  final String phone;
  bool selected = true;
}

class PhoneDiscoveryController extends ChangeNotifier {
  PhoneDiscoveryController(this.repository, this.actions) {
    _identity = repository.identityChanges.listen(
      (id) {
        if (id != repository.userId) {
          _authorized = false;
          contacts.clear();
          results = const [];
          lookup = null;
          pendingPhone = null;
          status = null;
          _notify();
        }
      },
      onError: (Object _) {
        error = const PhoneDiscoveryException('sign_in_required').toString();
        _notify();
      },
    );
  }
  final PhoneDiscoveryRepository repository;
  final InvitationActions actions;
  late final StreamSubscription<String?> _identity;
  bool _authorized = true;
  bool _disposed = false;
  bool busy = false;
  bool? smsAvailable;
  PhoneDiscoveryStatus? status;
  String? pendingPhone;
  String? error;
  String? notice;
  final contacts = <DiscoveryContact>[];
  List<DiscoveryContact> results = const [];
  PhoneLookup? lookup;
  bool get current =>
      !_disposed &&
      _authorized &&
      repository.currentUserId == repository.userId;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (!current || busy) return;
    busy = true;
    error = null;
    notice = null;
    _notify();
    try {
      await operation();
    } catch (failure) {
      if (current) {
        error = failure is PhoneDiscoveryException
            ? failure.toString()
            : const PhoneDiscoveryException('server_unavailable').toString();
      }
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refresh() => _run(() async {
    final value = await repository.status();
    if (!current) return;
    status = value;
    final available = await repository.smsEnabled();
    if (current) smsAvailable = available;
  });
  Future<void> requestCode(String phone) => _run(() async {
    await repository.requestCode(phone.trim());
    if (current) pendingPhone = phone.trim();
  });
  Future<void> verify(String code) => _run(() async {
    final phone = pendingPhone;
    if (phone == null || code.trim().isEmpty) {
      throw const PhoneDiscoveryException('invalid_otp');
    }
    final verified = await repository.verifyCode(phone, code.trim());
    if (!current) return;
    final updated = await repository.status();
    if (!current) return;
    status = updated;
    if (verified) {
      pendingPhone = null;
      notice = 'Phone verified. Choose whether people can find you.';
    } else {
      notice =
          'Enter the remaining verification code to finish changing your number.';
    }
  });
  Future<void> setConsent(bool enabled) => _run(() async {
    final expected = status;
    if (expected == null) return;
    try {
      final updated = await repository.consent(enabled, expected);
      if (current) status = updated;
    } catch (failure) {
      // A lost acknowledgement or conflict is resolved by reading fresh state.
      // Never replay an old consent mutation after a later withdrawal.
      final updated = await repository.status();
      if (current) status = updated;
      if (failure is PhoneDiscoveryException &&
          failure.code != 'server_unavailable') {
        rethrow;
      }
      if (current) {
        notice = 'Phone settings refreshed. Review your current choice.';
      }
    }
  });
  Future<void> pickContacts() async {
    if (!current || busy) return;
    // Keep Contact Picker directly on the user gesture.
    final selection = Future<InvitationContactSelection>.sync(
      actions.pickContacts,
    );
    await _run(() async {
      final chosen = await selection;
      if (!current) return;
      if (chosen.result == InvitationActionResult.cancelled) return;
      if (chosen.result != InvitationActionResult.completed) {
        notice =
            'Contact selection is unavailable. Add the numbers you want to check below.';
        return;
      }
      for (final contact in chosen.contacts) {
        for (final phone in contact.phones) {
          _add(contact.name, phone);
        }
      }
    });
  }

  void _add(String name, String phone) {
    if (contacts.any((item) => item.phone == phone)) return;
    contacts.add(DiscoveryContact(name, phone));
    lookup = null;
    results = const [];
  }

  void addNumber(String phone) {
    if (!current || busy || phone.trim().isEmpty) return;
    _add('', phone.trim());
    _notify();
  }

  void select(DiscoveryContact contact, bool selected) {
    if (!current || busy) return;
    contact.selected = selected;
    lookup = null;
    results = const [];
    _notify();
  }

  Future<void> find(String country) => _run(() async {
    final selected = contacts.where((item) => item.selected).toList();
    final normalizedCountry = country.trim().toUpperCase();
    if (selected.isEmpty ||
        selected.length > 50 ||
        (normalizedCountry.isNotEmpty &&
            !RegExp(r'^[A-Z]{2}$').hasMatch(normalizedCountry))) {
      throw const PhoneDiscoveryException('invalid_request');
    }
    final found = await repository.lookup(
      selected.map((item) => item.phone).toList(),
      normalizedCountry.isEmpty ? null : normalizedCountry,
    );
    if (!current) return;
    results = List.unmodifiable(selected);
    lookup = found;
  });
  void clearContacts() {
    if (busy) return;
    contacts.clear();
    lookup = null;
    results = const [];
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    contacts.clear();
    results = const [];
    pendingPhone = null;
    unawaited(_identity.cancel());
    repository.dispose();
    super.dispose();
  }
}
