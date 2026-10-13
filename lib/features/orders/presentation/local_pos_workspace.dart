import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/mizzy_database.dart';
import '../data/order_repository.dart';

/// Local-only Counter, Orders and Kitchen views over one SQLite order store.
///
/// This is deliberately marked as a development workspace. It does not process
/// real payments or synchronize with a hosted database.
class LocalPosWorkspace extends StatefulWidget {
  const LocalPosWorkspace({super.key, this.database});

  /// Optional injected database for isolated widget tests.
  final MizzyDatabase? database;

  @override
  State<LocalPosWorkspace> createState() => _LocalPosWorkspaceState();
}

class _LocalPosWorkspaceState extends State<LocalPosWorkspace> {
  static const _uuid = Uuid();
  static const _menu = <_DemoMenuItem>[
    _DemoMenuItem(
      id: 'adobo',
      name: 'Chicken Adobo',
      category: 'Meals',
      priceMinor: 14900,
    ),
    _DemoMenuItem(
      id: 'pancit',
      name: 'Pancit Canton',
      category: 'Meals',
      priceMinor: 12900,
    ),
    _DemoMenuItem(
      id: 'sisig',
      name: 'Pork Sisig',
      category: 'Meals',
      priceMinor: 17900,
    ),
    _DemoMenuItem(
      id: 'rice',
      name: 'Steamed Rice',
      category: 'Sides',
      priceMinor: 2500,
    ),
    _DemoMenuItem(
      id: 'iced-tea',
      name: 'Iced Tea',
      category: 'Drinks',
      priceMinor: 3500,
    ),
    _DemoMenuItem(
      id: 'water',
      name: 'Bottled Water',
      category: 'Drinks',
      priceMinor: 2000,
    ),
  ];

  late final bool _ownsDatabase;
  late final MizzyDatabase _database;
  late final OrderRepository _orders;
  final Map<String, int> _cart = <String, int>{};

  String? _organizationId;
  String? _branchId;
  List<Map<String, Object?>> _orderRows = const [];
  int _selectedTab = 0;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _ownsDatabase = widget.database == null;
    _database = widget.database ?? MizzyDatabase();
    _orders = OrderRepository(database: _database);
    _initializeLocalWorkspace();
  }

  @override
  void dispose() {
    if (_ownsDatabase) unawaited(_database.close());
    super.dispose();
  }

  Future<String> _stableLocalId(String key) async {
    final database = await _database.open();
    final rows = await database.query(
      'local_meta',
      columns: <String>['meta_value'],
      where: 'meta_key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      return rows.single['meta_value']! as String;
    }

    final value = _uuid.v4();
    await database.insert('local_meta', <String, Object?>{
      'meta_key': key,
      'meta_value': value,
    });
    return value;
  }

  Future<void> _initializeLocalWorkspace() async {
    try {
      final organizationId = await _stableLocalId('local_demo_organization_id');
      final branchId = await _stableLocalId('local_demo_branch_id');
      if (!mounted) return;
      setState(() {
        _organizationId = organizationId;
        _branchId = branchId;
      });
      await _refreshOrders();
    } on Object {
      if (!mounted) return;
      setState(
        () =>
            _error = 'Could not open local storage. Restart the app and retry.',
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refreshOrders() async {
    final organizationId = _organizationId;
    final branchId = _branchId;
    if (organizationId == null || branchId == null) return;

    try {
      final rows = await _orders.listOrders(
        organizationId: organizationId,
        branchId: branchId,
      );
      if (!mounted) return;
      setState(() {
        _orderRows = rows;
        _error = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not load local orders. Try refreshing.');
    }
  }

  int get _cartTotalMinor => _menu.fold<int>(
    0,
    (total, item) => total + item.priceMinor * (_cart[item.id] ?? 0),
  );

  Future<void> _saveOrder() async {
    if (_saving || _cart.isEmpty) return;
    final organizationId = _organizationId;
    final branchId = _branchId;
    if (organizationId == null || branchId == null) {
      setState(() => _error = 'Local workspace is still initializing.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });

    try {
      final lines = _menu
          .where((item) => (_cart[item.id] ?? 0) > 0)
          .map(
            (item) => OrderLineDraft(
              itemName: item.name,
              quantityMilli: _cart[item.id]! * 1000,
              unitPriceMinor: item.priceMinor,
            ),
          )
          .toList(growable: false);

      final result = await _orders.saveOrder(
        CreateOrderDraft(
          orderId: _uuid.v4(),
          idempotencyKey: _uuid.v4(),
          organizationId: organizationId,
          branchId: branchId,
          orderType: MizzyOrderType.takeaway,
          lines: lines,
          currencyCode: 'PHP',
        ),
      );
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _selectedTab = 1;
        _notice =
            'Order #${result.localOrderNumber} saved to Orders and Kitchen.';
      });
      await _refreshOrders();
    } on Object {
      if (!mounted) return;
      setState(
        () => _error = 'Order was not confirmed. Review the cart and retry.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _advanceKitchen(Map<String, Object?> order) async {
    final organizationId = _organizationId;
    final branchId = _branchId;
    if (organizationId == null || branchId == null) return;

    final currentStatus = order['status'] as String? ?? 'saved';
    final nextStatus = switch (currentStatus) {
      'saved' => KitchenTicketStatus.preparing,
      'preparing' => KitchenTicketStatus.ready,
      'ready' => KitchenTicketStatus.served,
      _ => null,
    };
    if (nextStatus == null) return;

    try {
      await _orders.updateKitchenStatus(
        organizationId: organizationId,
        branchId: branchId,
        orderId: order['id']! as String,
        nextStatus: nextStatus,
      );
      await _refreshOrders();
      if (!mounted) return;
      setState(
        () => _notice =
            'Order #${order['local_order_number']} updated to ${nextStatus.storageValue}.',
      );
    } on Object {
      if (!mounted) return;
      setState(
        () => _error = 'Kitchen status was not changed. Refresh and retry.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mizzy POS · Local demo'),
        actions: [
          IconButton(
            tooltip: 'Refresh orders',
            onPressed: _loading ? null : _refreshOrders,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: const Row(
                    children: [
                      Icon(Icons.cloud_off_outlined, size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Local-only development mode. Orders stay on this device; cloud sync and real payments are not enabled.',
                        ),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  MaterialBanner(
                    content: Text(_error!),
                    leading: const Icon(Icons.error_outline),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _error = null),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                if (_notice != null)
                  MaterialBanner(
                    content: Text(_notice!),
                    leading: const Icon(Icons.check_circle_outline),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _notice = null),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedTab,
                    children: [
                      _buildCounter(),
                      _buildOrderList(kitchen: false),
                      _buildOrderList(kitchen: true),
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedTab,
        onDestinationSelected: (index) {
          setState(() {
            _selectedTab = index;
            _notice = null;
          });
          if (index != 0) _refreshOrders();
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.point_of_sale_outlined),
            selectedIcon: Icon(Icons.point_of_sale),
            label: 'Counter',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Orders',
          ),
          NavigationDestination(
            icon: Icon(Icons.soup_kitchen_outlined),
            selectedIcon: Icon(Icons.soup_kitchen),
            label: 'Kitchen',
          ),
        ],
      ),
    );
  }

  Widget _buildCounter() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final menu = _buildMenu();
        final cart = _buildCart();
        if (constraints.maxWidth >= 720) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: menu),
              SizedBox(width: 360, child: cart),
            ],
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Menu', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            ..._menu.map(_buildMenuItem),
            const SizedBox(height: 12),
            cart,
          ],
        );
      },
    );
  }

  Widget _buildMenu() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Menu', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        ..._menu.map(_buildMenuItem),
      ],
    );
  }

  Widget _buildMenuItem(_DemoMenuItem item) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(item.name.substring(0, 1))),
        title: Text(item.name),
        subtitle: Text('${item.category} · ${_formatMoney(item.priceMinor)}'),
        trailing: IconButton(
          tooltip: 'Add ${item.name}',
          onPressed: _saving
              ? null
              : () => setState(() {
                  _cart.update(
                    item.id,
                    (count) => count + 1,
                    ifAbsent: () => 1,
                  );
                }),
          icon: const Icon(Icons.add_circle_outline),
        ),
      ),
    );
  }

  Widget _buildCart() {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Current order', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_cart.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Add menu items to start an order.'),
              )
            else
              ..._menu.where((item) => (_cart[item.id] ?? 0) > 0).map((item) {
                final count = _cart[item.id]!;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(item.name)),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Remove one ${item.name}',
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                if (count <= 1) {
                                  _cart.remove(item.id);
                                } else {
                                  _cart[item.id] = count - 1;
                                }
                              }),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$count'),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Add one ${item.name}',
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _cart[item.id] = count + 1;
                              }),
                        icon: const Icon(Icons.add_circle_outline),
                      ),
                      Text(_formatMoney(item.priceMinor * count)),
                    ],
                  ),
                );
              }),
            const Divider(),
            Row(
              children: [
                const Expanded(child: Text('Total')),
                Text(
                  _formatMoney(_cartTotalMinor),
                  style: theme.textTheme.titleLarge,
                ),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _cart.isEmpty || _saving ? null : _saveOrder,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: Text(_saving ? 'Saving…' : 'Save & send to Kitchen'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderList({required bool kitchen}) {
    final visibleOrders = kitchen
        ? _orderRows
              .where(
                (row) => !<String>{
                  'served',
                  'completed',
                  'cancelled',
                }.contains(row['status']),
              )
              .toList()
        : _orderRows;
    if (visibleOrders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                kitchen
                    ? Icons.soup_kitchen_outlined
                    : Icons.receipt_long_outlined,
                size: 44,
              ),
              const SizedBox(height: 12),
              Text(
                kitchen ? 'No active kitchen tickets' : 'No orders saved yet',
              ),
              const SizedBox(height: 8),
              Text(
                kitchen
                    ? 'New saved orders appear here automatically.'
                    : 'Save an order from Counter to see it here.',
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(
          kitchen ? 'Kitchen tickets' : 'Orders',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        ...visibleOrders.map((order) {
          final status = order['status'] as String? ?? 'saved';
          final number = order['local_order_number'] as int? ?? 0;
          final total = order['total_minor'] as int? ?? 0;
          final canAdvance =
              kitchen &&
              <String>{'saved', 'preparing', 'ready'}.contains(status);
          return Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(number.toString())),
              title: Text('Order #$number'),
              subtitle: Text(
                '${status.toUpperCase()} · ${order['order_type']}',
              ),
              trailing: kitchen && canAdvance
                  ? FilledButton(
                      onPressed: () => _advanceKitchen(order),
                      child: Text(switch (status) {
                        'saved' => 'Start',
                        'preparing' => 'Mark ready',
                        'ready' => 'Serve',
                        _ => 'Update',
                      }),
                    )
                  : Text(
                      _formatMoney(total),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
            ),
          );
        }),
      ],
    );
  }

  static String _formatMoney(int minorUnits) =>
      '₱${(minorUnits / 100).toStringAsFixed(2)}';
}

class _DemoMenuItem {
  const _DemoMenuItem({
    required this.id,
    required this.name,
    required this.category,
    required this.priceMinor,
  });

  final String id;
  final String name;
  final String category;
  final int priceMinor;
}
