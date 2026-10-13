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
    if (supabasePublishableKey.trim().isEmpty ||
        supabasePublishableKey.toLowerCase().contains('replace-me')) {
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
}
