import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_environment.dart';

enum CloudBootstrapStatus {
  notConfigured,
  clientInitialized,
  initializationFailed,
}

/// Initializes Supabase only when build-time public configuration is valid.
///
/// Publishable keys are client-facing keys intended to be protected by RLS.
/// Service-role keys must never be packaged with this app.
class SupabaseBootstrap {
  const SupabaseBootstrap._();

  static Future<CloudBootstrapStatus> initialize(
    AppEnvironment environment,
  ) async {
    if (!environment.hasUsableSupabaseConfiguration) {
      return CloudBootstrapStatus.notConfigured;
    }

    if (!Supabase.instance.isInitialized) {
      await Supabase.initialize(
        url: environment.supabaseUrl.trim(),
        publishableKey: environment.supabasePublishableKey.trim(),
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
        ),
      );
    }

    return CloudBootstrapStatus.clientInitialized;
  }
}
