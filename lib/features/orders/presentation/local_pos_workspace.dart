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
  static const _demoCatalog = <_DemoMenuSeed>[
    _DemoMenuSeed(
      sku: 'MIZ-ADOB-001',
      name: 'Chicken Adobo',
      category: 'Meals',
      priceMinor: 14900,
    ),
    _DemoMenuSeed(
      sku: 'MIZ-PANC-001',
      name: 'Pancit Canton',
      category: 'Meals',
      priceMinor: 12900,
    ),
    _DemoMenuSeed(
      sku: 'MIZ-SISIG-001',
      name: 'Pork Sisig',
      category: 'Meals',
      priceMinor: 17900,
    ),
    _DemoMenuSeed(
      sku: 'MIZ-RICE-001',
      name: 'Steamed Rice',
      category: 'Sides',
      priceMinor: 2500,
    ),
    _DemoMenuSeed(
      sku: 'MIZ-TEA-001',
      name: 'Iced Tea',
      category: 'Drinks',
      priceMinor: 3500,
    ),
    _DemoMenuSeed(
      sku: 'MIZ-WATER-001',
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
  List<Map<String, Object?>> _tableRows = const [];
  List<_DemoMenuItem> _menuItems = const [];
  MizzyOrderType _selectedOrderType = MizzyOrderType.takeaway;
  String? _selectedTableId;
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
      await _ensureDemoTables(organizationId, branchId);
      await _ensureDemoCatalog(organizationId, branchId);
      await _refreshTables();
      await _refreshMenu();
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

  Future<void> _ensureDemoTables(String organizationId, String branchId) async {
    final database = await _database.open();
    await database.transaction((transaction) async {
      final existing = await transaction.query(
        'restaurant_tables',
        columns: <String>['id'],
        where: 'organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[organizationId, branchId],
        limit: 1,
      );
      if (existing.isNotEmpty) return;

      final timestamp = DateTime.now().toUtc().toIso8601String();
      for (var index = 1; index <= 8; index++) {
        await transaction.insert('restaurant_tables', <String, Object?>{
          'id': _uuid.v4(),
          'organization_id': organizationId,
          'branch_id': branchId,
          'name': 'T$index',
          'area_name': index <= 4 ? 'Dining' : 'Patio',
          'capacity': index <= 4 ? 2 : 4,
          'status': 'available',
          'updated_at': timestamp,
          'sync_state': 'local',
        });
      }
    });
  }

  Future<void> _ensureDemoCatalog(
    String organizationId,
    String branchId,
  ) async {
    final database = await _database.open();
    await database.transaction((transaction) async {
      final existing = await transaction.query(
        'catalog_items',
        columns: <String>['id'],
        where: 'organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[organizationId, branchId],
        limit: 1,
      );
      if (existing.isNotEmpty) return;

      final timestamp = DateTime.now().toUtc().toIso8601String();
      for (final item in _demoCatalog) {
        await transaction.insert('catalog_items', <String, Object?>{
          'id': _uuid.v4(),
          'organization_id': organizationId,
          'branch_id': branchId,
          'name': item.name,
          'sku': item.sku,
          'category_name': item.category,
          'price_minor': item.priceMinor,
          'currency_code': 'PHP',
          'is_active': 1,
          'updated_at': timestamp,
          'sync_state': 'local',
        });
      }
    });
  }

  Future<void> _refreshMenu() async {
    final organizationId = _organizationId;
    final branchId = _branchId;
    if (organizationId == null || branchId == null) return;

    try {
      final database = await _database.open();
      final rows = await database.query(
        'catalog_items',
        where: 'organization_id = ? AND branch_id = ? AND is_active = ?',
        whereArgs: <Object?>[organizationId, branchId, 1],
        orderBy: 'category_name COLLATE NOCASE ASC, name COLLATE NOCASE ASC',
      );
      if (!mounted) return;
      setState(() {
        _menuItems = rows
            .map((row) {
              return _DemoMenuItem(
                id: row['id']! as String,
                sku: row['sku'] as String?,
                name: row['name']! as String,
                category: row['category_name'] as String? ?? 'Other',
                priceMinor: row['price_minor']! as int,
              );
            })
            .toList(growable: false);
      });
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not load the local menu catalog.');
    }
  }

  Future<void> _refreshTables() async {
    final organizationId = _organizationId;
    final branchId = _branchId;
    if (organizationId == null || branchId == null) return;

    try {
      final database = await _database.open();
      final rows = await database.query(
        'restaurant_tables',
        where: 'organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[organizationId, branchId],
        orderBy: 'name COLLATE NOCASE ASC',
      );
      if (!mounted) return;
      setState(() => _tableRows = rows);
    } on Object {
      if (!mounted) return;
      setState(() => _error = 'Could not load the local table layout.');
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

  String? get _selectedTableName {
    final selectedTableId = _selectedTableId;
    if (selectedTableId == null) return null;
    for (final table in _tableRows) {
      if (table['id'] == selectedTableId) {
        return table['name'] as String?;
      }
    }
    return null;
  }

  void _chooseTable(Map<String, Object?> table) {
    if (table['status'] != 'available') return;
    setState(() {
      _selectedOrderType = MizzyOrderType.dineIn;
      _selectedTableId = table['id']! as String;
      _selectedTab = 0;
      _error = null;
      _notice = '${table['name']} selected for dine-in.';
    });
  }

  int get _cartTotalMinor => _menuItems.fold<int>(
    0,
    (total, item) => total + item.priceMinor * (_cart[item.id] ?? 0),
  );

  Future<void> _saveOrder() async {
    if (_saving || _cart.isEmpty) return;
    if (_selectedOrderType == MizzyOrderType.dineIn &&
        _selectedTableId == null) {
      setState(() {
        _selectedTab = 1;
        _error = 'Choose an available table before saving a dine-in order.';
      });
      return;
    }
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
      final lines = _menuItems
          .where((item) => (_cart[item.id] ?? 0) > 0)
          .map(
            (item) => OrderLineDraft(
              catalogItemId: item.id,
              itemName: item.name,
              sku: item.sku,
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
          orderType: _selectedOrderType,
          tableId: _selectedOrderType == MizzyOrderType.dineIn
              ? _selectedTableId
              : null,
          lines: lines,
          currencyCode: 'PHP',
        ),
      );
      if (!mounted) return;
      setState(() {
        _cart.clear();
        _selectedOrderType = MizzyOrderType.takeaway;
        _selectedTableId = null;
        _selectedTab = 2;
        _notice =
            'Order #${result.localOrderNumber} saved to Orders and Kitchen.';
      });
      await _refreshOrders();
      await _refreshTables();
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
      await _refreshTables();
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
            onPressed: _loading
                ? null
                : () {
                    _refreshOrders();
                    _refreshTables();
                  },
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
                      _buildTableLayout(),
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
          if (index != 0) {
            _refreshOrders();
            _refreshTables();
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.point_of_sale_outlined),
            selectedIcon: Icon(Icons.point_of_sale),
            label: 'Counter',
          ),
          NavigationDestination(
            icon: Icon(Icons.table_restaurant_outlined),
            selectedIcon: Icon(Icons.table_restaurant),
            label: 'Tables',
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

  Widget _buildTableLayout() {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Table layout', style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Choose an available table to start a dine-in order.'),
        const SizedBox(height: 16),
        if (_tableRows.isEmpty)
          const Center(child: Text('No tables configured for this branch.'))
        else
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _tableRows.map((table) {
              final name = table['name'] as String? ?? 'Table';
              final status = table['status'] as String? ?? 'inactive';
              final available = status == 'available';
              final capacity = table['capacity'] as int? ?? 2;
              return SizedBox(
                width: 168,
                height: 176,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          available
                              ? Icons.table_restaurant_outlined
                              : Icons.event_seat_outlined,
                        ),
                        const SizedBox(height: 6),
                        Text(name, style: theme.textTheme.titleMedium),
                        Text(status.toUpperCase()),
                        Text('$capacity seats'),
                        const Spacer(),
                        if (available)
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              onPressed: () => _chooseTable(table),
                              child: const Text('Use table'),
                            ),
                          )
                        else
                          const Text('Unavailable'),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
      ],
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
            ..._menuItems.map(_buildMenuItem),
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
        ..._menuItems.map(_buildMenuItem),
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
            DropdownButtonFormField<MizzyOrderType>(
              key: ValueKey(_selectedOrderType),
              initialValue: _selectedOrderType,
              decoration: const InputDecoration(
                labelText: 'Order type',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: MizzyOrderType.takeaway,
                  child: Text('Takeaway'),
                ),
                DropdownMenuItem(
                  value: MizzyOrderType.dineIn,
                  child: Text('Dine-in'),
                ),
                DropdownMenuItem(
                  value: MizzyOrderType.delivery,
                  child: Text('Delivery'),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedOrderType = value;
                        if (value != MizzyOrderType.dineIn) {
                          _selectedTableId = null;
                        }
                      });
                    },
            ),
            if (_selectedOrderType == MizzyOrderType.dineIn)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _selectedTableName == null
                            ? 'No table selected'
                            : 'Table: $_selectedTableName',
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _saving
                          ? null
                          : () => setState(() => _selectedTab = 1),
                      icon: const Icon(Icons.table_restaurant_outlined),
                      label: const Text('Choose table'),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            if (_cart.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Add menu items to start an order.'),
              )
            else
              ..._menuItems.where((item) => (_cart[item.id] ?? 0) > 0).map((
                item,
              ) {
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
                <String>[
                  status.toUpperCase(),
                  order['order_type'] as String? ?? 'takeaway',
                  if (order['table_name'] is String)
                    order['table_name']! as String,
                ].join(' · '),
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

class _DemoMenuSeed {
  const _DemoMenuSeed({
    required this.sku,
    required this.name,
    required this.category,
    required this.priceMinor,
  });

  final String sku;
  final String name;
  final String category;
  final int priceMinor;
}

class _DemoMenuItem {
  const _DemoMenuItem({
    required this.id,
    required this.sku,
    required this.name,
    required this.category,
    required this.priceMinor,
  });

  final String id;
  final String? sku;
  final String name;
  final String category;
  final int priceMinor;
}
