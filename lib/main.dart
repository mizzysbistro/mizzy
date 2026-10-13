import 'package:flutter/material.dart';

import 'core/cloud/supabase_bootstrap.dart';
import 'core/config/app_environment.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final environment = AppEnvironment.fromDartDefines();
  var cloudStatus = CloudBootstrapStatus.notConfigured;
  try {
    cloudStatus = await SupabaseBootstrap.initialize(environment);
  } on Object {
    // Do not print configuration values or credentials to the logs.
    cloudStatus = CloudBootstrapStatus.initializationFailed;
  }
  runApp(MizzyApp(cloudBootstrapStatus: cloudStatus));
}

class MizzyApp extends StatelessWidget {
  const MizzyApp({
    super.key,
    this.cloudBootstrapStatus = CloudBootstrapStatus.notConfigured,
  });

  final CloudBootstrapStatus cloudBootstrapStatus;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Mizzy POS",
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF176B55),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: FoundationScreen(cloudBootstrapStatus: cloudBootstrapStatus),
    );
  }
}

class FoundationScreen extends StatelessWidget {
  const FoundationScreen({super.key, required this.cloudBootstrapStatus});

  final CloudBootstrapStatus cloudBootstrapStatus;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mizzy POS'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Tooltip(
                message: switch (cloudBootstrapStatus) {
                  CloudBootstrapStatus.notConfigured =>
                    'Cloud sync is not configured',
                  CloudBootstrapStatus.clientInitialized =>
                    'Cloud client initialized; sync is not active yet',
                  CloudBootstrapStatus.initializationFailed =>
                    'Cloud client initialization failed',
                },
                child: Icon(switch (cloudBootstrapStatus) {
                  CloudBootstrapStatus.notConfigured =>
                    Icons.cloud_off_outlined,
                  CloudBootstrapStatus.clientInitialized =>
                    Icons.cloud_done_outlined,
                  CloudBootstrapStatus.initializationFailed =>
                    Icons.cloud_off_outlined,
                }),
              ),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Your restaurant, connected.',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  'The independent Mizzy POS foundation is initialized. '
                  'Core ordering, kitchen, inventory, and cloud features '
                  'will be added and verified in the P0–P6 build loop.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 20),
                const _StatusRow(
                  icon: Icons.phone_android,
                  label: 'Android application shell',
                  value: 'Foundation',
                ),
                const _StatusRow(
                  icon: Icons.storage_outlined,
                  label: 'Local persistence',
                  value: 'SQLite foundation; UI pending',
                ),
                _StatusRow(
                  icon: Icons.cloud_outlined,
                  label: 'Supabase client',
                  value: switch (cloudBootstrapStatus) {
                    CloudBootstrapStatus.notConfigured => 'Not configured',
                    CloudBootstrapStatus.clientInitialized =>
                      'Initialized; sync pending',
                    CloudBootstrapStatus.initializationFailed =>
                      'Initialization failed',
                  },
                ),
                const SizedBox(height: 20),
                const Text(
                  'This is a development scaffold, not a finished POS. '
                  'The SQLite order repository is not yet connected to POS screens. '
                  'Payments, user sign-in, and live cloud synchronization are not active.',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
          const SizedBox(width: 12),
          Text(value, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
  }
}
