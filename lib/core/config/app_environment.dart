import 'dart:convert';

/// Build-time configuration for public client settings only.
///
/// Define values with --dart-define or --dart-define-from-file. Never pass a
/// Supabase service-role key to a Flutter/mobile build.
class AppEnvironment {
  const AppEnvironment({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    this.allowInsecureLocalDevelopment = false,
  });

  factory AppEnvironment.fromDartDefines() {
    return const AppEnvironment(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      allowInsecureLocalDevelopment: bool.fromEnvironment(
        'SUPABASE_ALLOW_INSECURE_LOCAL',
        defaultValue: false,
      ),
    );
  }

  final String supabaseUrl;
  final String supabasePublishableKey;
  final bool allowInsecureLocalDevelopment;

  bool get hasUsableSupabaseConfiguration {
    final key = supabasePublishableKey.trim();
    if (key.isEmpty ||
        key.toLowerCase().contains('replace-me') ||
        _isPrivilegedKey(key)) {
      return false;
    }

    final uri = Uri.tryParse(supabaseUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      return false;
    }

    if (uri.scheme == 'https') {
      return true;
    }

    const localHosts = <String>{'localhost', '127.0.0.1', '10.0.2.2'};
    return allowInsecureLocalDevelopment &&
        uri.scheme == 'http' &&
        localHosts.contains(uri.host);
  }

  bool _isPrivilegedKey(String key) {
    if (key.startsWith('sb_secret_')) {
      return true;
    }

    // Older Supabase service-role keys are JWTs. Do not allow a JWT whose
    // decoded role claim is service_role to be embedded into a mobile build.
    final segments = key.split('.');
    if (segments.length != 3) {
      return false;
    }

    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
      );
      return payload is Map<String, dynamic> &&
          payload['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }
}
