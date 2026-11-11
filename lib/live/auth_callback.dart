import 'package:supabase_flutter/supabase_flutter.dart';

const authCallbackFailureMessage =
    'Sign-in did not finish. Your profile draft is saved. Please try again.';

enum AuthCallbackResult { none, succeeded, failed }

const _credentials = {'code', 'access_token'};
const _errors = {'error', 'error_code', 'error_description'};
const _authParameters = {
  ..._credentials,
  ..._errors,
  'expires_in',
  'expires_at',
  'refresh_token',
  'token_type',
  'provider_token',
  'provider_refresh_token',
  'type',
  'sb_flow_id',
  'token',
  'token_hash',
  'otp',
};

String? _decoded(String value) {
  try {
    return Uri.decodeQueryComponent(value);
  } on FormatException {
    return null;
  }
}

String? _parameterKey(String part) => _decoded(part.split('=').first);
bool _callbackMarker(String part) =>
    _parameterKey(part) == 'auth' &&
    part.contains('=') &&
    _decoded(part.substring(part.indexOf('=') + 1)) == 'callback';

bool isAuthCallback(Uri uri) => [uri.query, uri.fragment].any(
  (parameters) => parameters.split('&').any((part) {
    final key = _parameterKey(part);
    return _callbackMarker(part) ||
        _credentials.contains(key) ||
        _errors.contains(key);
  }),
);

/// Runs the SDK exchange once so a failed redirect has an explicit UI result.
/// Error descriptions and credentials never become application messages.
Future<AuthCallbackResult> completeAuthCallback(
  SupabaseClient client,
  Uri uri,
) async {
  if (!isAuthCallback(uri)) return AuthCallbackResult.none;
  try {
    final parameters = {
      ...uri.queryParameters,
      ...Uri.splitQueryString(uri.fragment),
    };
    if (_errors.any(parameters.containsKey) ||
        !_credentials.any((key) => parameters[key]?.isNotEmpty == true)) {
      return AuthCallbackResult.failed;
    }
    await client.auth.getSessionFromUrl(uri);
    return AuthCallbackResult.succeeded;
  } catch (_) {
    return AuthCallbackResult.failed;
  }
}

/// Remove consumed credentials while retaining unrelated routes/invitations.
Uri withoutAuthCallbackParameters(Uri uri) {
  String clean(String parameters) => parameters
      .split('&')
      .where((part) {
        final key = _parameterKey(part);
        return key != null &&
            !_authParameters.contains(key) &&
            !_callbackMarker(part);
      })
      .join('&');
  final query = clean(uri.query);
  final fragment = clean(uri.fragment);
  if (query == uri.query && fragment == uri.fragment) return uri;
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    query: query.isEmpty ? null : query,
    fragment: fragment.isEmpty ? null : fragment,
  );
}
