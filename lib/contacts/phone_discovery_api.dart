import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../push/push_browser_types.dart';

class PhoneDiscoveryException implements Exception {
  const PhoneDiscoveryException(this.code);
  final String code;
  @override
  String toString() => switch (code) {
    'sms_unavailable' =>
      'SMS verification is being configured. You can use the app and invite friends now.',
    'phone_verification_required' =>
      'Verify your phone number before finding contacts.',
    'identity_changed' ||
    'sign_in_required' ||
    'session_revoked' => 'Sign in again to continue with this account.',
    'phone_changed' || 'discovery_state_changed' =>
      'Your preferences changed. Review the latest settings and choose again.',
    'invalid_phone' => 'Enter a phone number with its +country code.',
    'invalid_otp' || 'otp_expired' => 'Check the SMS code and retry.',
    'phone_exists' => 'This phone number already belongs to another account.',
    'rate_limited' ||
    'over_sms_send_rate_limit' => 'Too many attempts. Wait a minute and retry.',
    'invalid_request' =>
      'Select up to 50 numbers and check the two-letter country code.',
    _ => 'Could not update phone discovery. Check your connection and retry.',
  };
}

class PhoneDiscoveryStatus {
  const PhoneDiscoveryStatus({
    required this.verified,
    required this.discoverable,
    this.last4,
    this.phoneRevision,
    this.consentRevision,
  });
  final bool verified;
  final bool discoverable;
  final String? last4;
  final String? phoneRevision;
  final String? consentRevision;
  factory PhoneDiscoveryStatus.fromJson(Map<String, dynamic> value) {
    final revision = value['phone_revision'];
    final consent = value['consent_revision'];
    if (value['has_verified_phone'] is! bool ||
        value['discoverable'] is! bool ||
        (revision != null &&
            (revision is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(revision))) ||
        (consent != null &&
            (consent is! String || !pushUuid.hasMatch(consent)))) {
      throw const PhoneDiscoveryException('server_unavailable');
    }
    return PhoneDiscoveryStatus(
      verified: value['has_verified_phone'] as bool,
      discoverable: value['discoverable'] as bool,
      last4: value['phone_last4'] as String?,
      phoneRevision: revision as String?,
      consentRevision: consent as String?,
    );
  }
}

class PhoneLookup {
  const PhoneLookup(this.matches, this.invalid);
  final Map<int, String> matches;
  final Set<int> invalid;
}

abstract interface class PhoneDiscoveryRepository {
  String get userId;
  String? get currentUserId;
  Stream<String?> get identityChanges;
  Future<PhoneDiscoveryStatus> status();
  Future<bool> smsEnabled();
  Future<void> requestCode(String phone);
  Future<bool> verifyCode(String phone, String code);
  Future<PhoneDiscoveryStatus> consent(
    bool enabled,
    PhoneDiscoveryStatus expected,
  );
  Future<PhoneLookup> lookup(List<String> phones, String? country);
  void dispose();
}

class SupabasePhoneDiscoveryApi implements PhoneDiscoveryRepository {
  SupabasePhoneDiscoveryApi(
    this.client,
    this.userId, {
    required this.url,
    required this.key,
    http.Client? authTransport,
  }) : _authTransport = authTransport ?? http.Client();
  final SupabaseClient client;
  final String url;
  final String key;
  final http.Client _authTransport;
  @override
  final String userId;
  @override
  String? get currentUserId => client.auth.currentUser?.id;
  @override
  Stream<String?> get identityChanges =>
      client.auth.onAuthStateChange.map((event) => event.session?.user.id);
  void _checkIdentity() {
    if (currentUserId != userId) {
      throw const PhoneDiscoveryException('identity_changed');
    }
  }

  Future<Map<String, dynamic>> _call(
    String action, [
    Map<String, dynamic> fields = const {},
  ]) async {
    _checkIdentity();
    final token = client.auth.currentSession?.accessToken;
    if (token == null) throw const PhoneDiscoveryException('sign_in_required');
    try {
      final result = await client.functions
          .invoke(
            'phone-discovery',
            headers: {'Authorization': 'Bearer $token'},
            body: {'action': action, 'expected_user_id': userId, ...fields},
          )
          .timeout(const Duration(seconds: 25));
      _checkIdentity();
      return Map<String, dynamic>.from(result.data as Map);
    } on FunctionException catch (error) {
      _checkIdentity();
      final details = error.details;
      throw PhoneDiscoveryException(
        details is Map
            ? details['code'] as String? ?? 'server_unavailable'
            : 'server_unavailable',
      );
    }
  }

  @override
  Future<PhoneDiscoveryStatus> status() async =>
      PhoneDiscoveryStatus.fromJson(await _call('status'));
  @override
  Future<PhoneDiscoveryStatus> consent(
    bool enabled,
    PhoneDiscoveryStatus expected,
  ) async => PhoneDiscoveryStatus.fromJson(
    await _call('consent', {
      'enabled': enabled,
      'expected_consent_revision': expected.consentRevision,
      if (enabled) 'expected_phone_revision': expected.phoneRevision,
    }),
  );
  @override
  Future<PhoneLookup> lookup(List<String> phones, String? country) async {
    final value = await _call('lookup', {
      'phones': phones,
      if (country != null && country.isNotEmpty) 'default_country': country,
    });
    final matches = <int, String>{};
    final invalid = <int>{};
    for (final item in value['matches'] as List) {
      final index = item['index'];
      final id = item['profile_id'];
      if (index is! int ||
          index < 0 ||
          index >= phones.length ||
          id is! String ||
          !pushUuid.hasMatch(id)) {
        throw const PhoneDiscoveryException('server_unavailable');
      }
      matches[index] = id;
    }
    for (final index in value['invalid_indexes'] as List) {
      if (index is! int ||
          index < 0 ||
          index >= phones.length ||
          matches.containsKey(index)) {
        throw const PhoneDiscoveryException('server_unavailable');
      }
      invalid.add(index);
    }
    return PhoneLookup(Map.unmodifiable(matches), Set.unmodifiable(invalid));
  }

  @override
  Future<bool> smsEnabled() async {
    _checkIdentity();
    final response = await _authTransport
        .get(Uri.parse('$url/auth/v1/settings'), headers: {'apikey': key})
        .timeout(const Duration(seconds: 15));
    _checkIdentity();
    if (response.statusCode != 200) {
      throw const PhoneDiscoveryException('server_unavailable');
    }
    final data = jsonDecode(response.body) as Map;
    return (data['external'] as Map)['phone'] == true;
  }

  Future<Map<String, dynamic>> _authCall(
    String method,
    String path,
    Map<String, dynamic> body,
    Session session,
  ) async {
    _checkIdentity();
    final request = http.Request(method, Uri.parse('$url/auth/v1/$path'))
      ..headers.addAll({
        'apikey': key,
        'Authorization': 'Bearer ${session.accessToken}',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await _authTransport.send(request),
    ).timeout(const Duration(seconds: 25));
    _checkIdentity();
    final data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PhoneDiscoveryException(
        data['error_code'] as String? ??
            data['code'] as String? ??
            'server_unavailable',
      );
    }
    return data;
  }

  @override
  Future<void> requestCode(String phone) async {
    if (!RegExp(r'^\+[1-9][0-9]{1,14}$').hasMatch(phone)) {
      throw const PhoneDiscoveryException('invalid_phone');
    }
    if (!await smsEnabled()) {
      throw const PhoneDiscoveryException('sms_unavailable');
    }
    _checkIdentity();
    final session = client.auth.currentSession;
    if (session == null) {
      throw const PhoneDiscoveryException('sign_in_required');
    }
    final data = await _authCall('PUT', 'user', {'phone': phone}, session);
    if (data['id'] != userId) {
      throw const PhoneDiscoveryException('identity_changed');
    }
  }

  @override
  Future<bool> verifyCode(String phone, String code) async {
    _checkIdentity();
    final original = client.auth.currentSession;
    if (original == null) {
      throw const PhoneDiscoveryException('sign_in_required');
    }
    final data = await _authCall('POST', 'verify', {
      'phone': phone,
      'token': code,
      'type': 'phone_change',
    }, original);
    final auth = AuthResponse.fromJson(data);
    if (auth.user != null && auth.user!.id != userId) {
      throw const PhoneDiscoveryException('identity_changed');
    }
    final session = auth.session;
    if (session != null &&
        !session.isExpired &&
        identical(client.auth.currentSession, original)) {
      // In pinned gotrue 2.27.3 this validated, unexpired restoration writes
      // synchronously, before any await. A late OTP cannot replace another login.
      await client.auth.setInitialSession(jsonEncode(session.toJson()));
    }
    _checkIdentity();
    return auth.user?.phone?.replaceFirst(RegExp(r'^\+'), '') ==
            phone.substring(1) &&
        auth.user?.phoneConfirmedAt != null;
  }

  @override
  void dispose() => _authTransport.close();
}
