import 'package:flutter_test/flutter_test.dart';

import 'package:mizzy/core/config/app_environment.dart';

void main() {
  group('AppEnvironment', () {
    test('defaults to unconfigured when no build defines are provided', () {
      const environment = AppEnvironment(
        supabaseUrl: '',
        supabasePublishableKey: '',
      );

      expect(environment.hasUsableSupabaseConfiguration, isFalse);
    });

    test('rejects invalid schemes and empty host values', () {
      const missingHost = AppEnvironment(
        supabaseUrl: 'https:///path',
        supabasePublishableKey: 'public-key',
      );
      const insecureRemote = AppEnvironment(
        supabaseUrl: 'http://example.com',
        supabasePublishableKey: 'public-key',
        allowInsecureLocalDevelopment: true,
      );

      expect(missingHost.hasUsableSupabaseConfiguration, isFalse);
      expect(insecureRemote.hasUsableSupabaseConfiguration, isFalse);
    });

    test('accepts HTTPS URL with a publishable key', () {
      const environment = AppEnvironment(
        supabaseUrl: 'https://project-ref.supabase.co',
        supabasePublishableKey: 'sb_publishable_example',
      );

      expect(environment.hasUsableSupabaseConfiguration, isTrue);
    });

    test('permits plain HTTP only for explicit local development hosts', () {
      const emulator = AppEnvironment(
        supabaseUrl: 'http://10.0.2.2:54321',
        supabasePublishableKey: 'sb_publishable_local',
        allowInsecureLocalDevelopment: true,
      );
      const remote = AppEnvironment(
        supabaseUrl: 'http://203.0.113.20:54321',
        supabasePublishableKey: 'sb_publishable_local',
        allowInsecureLocalDevelopment: true,
      );

      expect(emulator.hasUsableSupabaseConfiguration, isTrue);
      expect(remote.hasUsableSupabaseConfiguration, isFalse);
    });

    test('rejects placeholder keys', () {
      const environment = AppEnvironment(
        supabaseUrl: 'https://project-ref.supabase.co',
        supabasePublishableKey: 'REPLACE-ME',
      );

      expect(environment.hasUsableSupabaseConfiguration, isFalse);
    });

    test('rejects modern secret keys and legacy service-role JWTs', () {
      const modernSecret = AppEnvironment(
        supabaseUrl: 'https://project-ref.supabase.co',
        supabasePublishableKey: 'sb_secret_not-for-mobile',
      );
      const legacyServiceRole = AppEnvironment(
        supabaseUrl: 'https://project-ref.supabase.co',
        supabasePublishableKey:
            'eyJhbGciOiJub25lIn0.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature',
      );

      expect(modernSecret.hasUsableSupabaseConfiguration, isFalse);
      expect(legacyServiceRole.hasUsableSupabaseConfiguration, isFalse);
    });
  });
}
