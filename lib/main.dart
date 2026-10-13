import 'package:flutter/material.dart';

void main() {
  runApp(const MizzyApp());
}

class MizzyApp extends StatelessWidget {
  const MizzyApp({super.key});

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
      home: const FoundationScreen(),
    );
  }
}

class FoundationScreen extends StatelessWidget {
  const FoundationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mizzy POS'),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Center(
              child: Tooltip(
                message: 'Cloud sync is not configured yet',
                child: Icon(Icons.cloud_off_outlined),
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
                  value: 'Not configured',
                ),
                const _StatusRow(
                  icon: Icons.cloud_outlined,
                  label: 'Supabase synchronization',
                  value: 'Not configured',
                ),
                const SizedBox(height: 20),
                const Text(
                  'This screen is a development scaffold, not a finished POS. '
                  'No orders, payments, or cloud sync are active yet.',
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
          Text(
            value,
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ],
      ),
    );
  }
}
