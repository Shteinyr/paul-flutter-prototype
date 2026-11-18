/// Public deployment settings only. Never place service/provider secrets here.
enum AppPurpose { app, preview, review, demo }

class AppConfiguration {
  const AppConfiguration({
    required this.purpose,
    required this.url,
    required this.key,
    required this.appUrl,
  });
  factory AppConfiguration.environment() => AppConfiguration(
    purpose: parsePurpose(
      const String.fromEnvironment('PAUL_TARGET', defaultValue: 'app'),
    ),
    url: const String.fromEnvironment(
      'SUPABASE_URL',
      defaultValue: 'https://ejopxxhgozsxygvkwrfr.supabase.co',
    ),
    key: const String.fromEnvironment(
      'SUPABASE_PUBLISHABLE_KEY',
      defaultValue: 'sb_publishable_JdGiMwZarYPXEaJCtL-uLQ_dWtJwFCF',
    ),
    appUrl: const String.fromEnvironment(
      'PAUL_APP_URL',
      defaultValue: 'https://shteinyr-community-network.web.app',
    ),
  );
  final AppPurpose purpose;
  final String url;
  final String key;
  final String appUrl;
  static AppPurpose parsePurpose(String value) => switch (value) {
    'app' => AppPurpose.app,
    'preview' => AppPurpose.preview,
    'review' => AppPurpose.review,
    'demo' => AppPurpose.demo,
    _ => throw ArgumentError.value(
      value,
      'PAUL_TARGET',
      'Use app, preview, review or demo',
    ),
  };
}
