import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/catalog/data/cloud_catalog_repository.dart';
import 'package:mizzy/features/orders/data/order_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late MizzyDatabase database;
  late _FakeCloudCatalogSource source;
  late CloudCatalogRepository repository;
  late String organizationId;
  late String branchId;
  late DateTime now;

  setUp(() {
    organizationId = const Uuid().v4();
    branchId = const Uuid().v4();
    now = DateTime.utc(2026, 10, 14, 12);
    database = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: 'mizzy-cloud-catalog-${const Uuid().v4()}.db',
    );
    source = _FakeCloudCatalogSource();
    repository = CloudCatalogRepository(
      database: database,
      source: source,
      hasBranchAccess: _allowBranchAccess,
      clock: () => now,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Map<String, Object?> item({
    String? id,
    String? organization,
    String? branch,
    String name = 'Chicken Adobo',
    String? sku = 'MIZ-ADOB-001',
    String? category = 'Meals',
    int priceMinor = 14900,
    String currencyCode = 'PHP',
    bool active = true,
    String? updatedAt,
  }) {
    return <String, Object?>{
      'id': id ?? const Uuid().v4(),
      'organization_id': organization ?? organizationId,
      'branch_id': branch ?? branchId,
      'name': name,
      'sku': sku,
      'category_name': category,
      'price_minor': priceMinor,
      'currency_code': currencyCode,
      'is_active': active,
      'updated_at': updatedAt ?? now.toIso8601String(),
    };
  }

  Future<Map<String, Object?>> readItem(String id) async {
    final db = await database.open();
    return (await db.query(
      'catalog_items',
      where: 'id = ? AND organization_id = ? AND branch_id = ?',
      whereArgs: <Object?>[id, organizationId, branchId],
      limit: 1,
    )).single;
  }

  test('requires active branch access before making a cloud request', () async {
    var sourceCalls = 0;
    final deniedRepository = CloudCatalogRepository(
      database: database,
      source: _CountingCloudCatalogSource(onFetch: () => sourceCalls++),
      hasBranchAccess: _denyBranchAccess,
      clock: () => now,
    );

    await expectLater(
      deniedRepository.syncBranch(
        organizationId: organizationId,
        branchId: branchId,
      ),
      throwsStateError,
    );
    expect(sourceCalls, 0);
    expect(await (await database.open()).query('catalog_items'), isEmpty);
  });

  test('imports stable cloud UUIDs and caches inactive items as unavailable', () async {
    final active = item(id: const Uuid().v4());
    final inactive = item(
      id: const Uuid().v4(),
      name: 'Retired Meal',
      sku: 'MIZ-OLD-001',
      active: false,
    );
    source.items = [active, inactive];

    final result = await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.received, 2);
    expect(result.inserted, 2);
    expect(result.updated, 0);
    expect(result.deactivated, 0);
    expect(result.conflicts, 0);
    expect((await readItem(active['id']! as String))['is_active'], 1);
    final retired = await readItem(inactive['id']! as String);
    expect(retired['is_active'], 0);
    expect(retired['sync_state'], 'synced');
  });

  test('updates cloud prices but preserves historical sale-line snapshots', () async {
    final catalogId = const Uuid().v4();
    source.items = [item(id: catalogId)];
    await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    final orders = OrderRepository(database: database);
    final orderId = const Uuid().v4();
    await orders.saveOrder(
      CreateOrderDraft(
        orderId: orderId,
        idempotencyKey: const Uuid().v4(),
        organizationId: organizationId,
        branchId: branchId,
        orderType: MizzyOrderType.takeaway,
        lines: [
          OrderLineDraft(
            catalogItemId: catalogId,
            itemName: 'Chicken Adobo',
            sku: 'MIZ-ADOB-001',
            quantityMilli: 1000,
            unitPriceMinor: 14900,
          ),
        ],
      ),
    );

    now = now.add(const Duration(minutes: 1));
    source.items = [
      item(
        id: catalogId,
        name: 'Chicken Adobo Updated',
        priceMinor: 16900,
        updatedAt: now.toIso8601String(),
      ),
    ];
    final result = await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    final cached = await readItem(catalogId);
    final db = await database.open();
    final line = (await db.query(
      'order_lines',
      where: 'order_id = ?',
      whereArgs: <Object?>[orderId],
      limit: 1,
    )).single;
    expect(result.updated, 1);
    expect(cached['name'], 'Chicken Adobo Updated');
    expect(cached['price_minor'], 16900);
    expect(line['item_name_snapshot'], 'Chicken Adobo');
    expect(line['unit_price_minor'], 14900);
  });

  test('deactivates an existing cached item when the cloud disables it', () async {
    final id = const Uuid().v4();
    source.items = [item(id: id, active: true)];
    await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    source.items = [item(id: id, active: false)];
    final result = await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.deactivated, 1);
    final cached = await readItem(id);
    expect(cached['is_active'], 0);
    expect(cached['sync_state'], 'synced');
  });

  test('deactivates removed items and frees a reused SKU without deleting history', () async {
    final oldId = const Uuid().v4();
    final newId = const Uuid().v4();
    source.items = [item(id: oldId, sku: 'REUSED-SKU')];
    await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    source.items = [
      item(id: newId, sku: 'REUSED-SKU', name: 'Replacement Item'),
    ];
    final result = await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    final oldItem = await readItem(oldId);
    final newItem = await readItem(newId);
    expect(result.inserted, 1);
    expect(result.deactivated, 1);
    expect(oldItem['is_active'], 0);
    expect(oldItem['sku'], isNull);
    expect(oldItem['sync_state'], 'synced');
    expect(newItem['is_active'], 1);
    expect(newItem['sku'], 'REUSED-SKU');
  });

  test('preserves conflicting unsynced values and disables the item for sale', () async {
    final id = const Uuid().v4();
    final db = await database.open();
    await db.insert('catalog_items', <String, Object?>{
      'id': id,
      'organization_id': organizationId,
      'branch_id': branchId,
      'name': 'Local Edited Name',
      'sku': 'MIZ-ADOB-001',
      'category_name': 'Meals',
      'price_minor': 9000,
      'currency_code': 'PHP',
      'is_active': 1,
      'updated_at': now.toIso8601String(),
      'sync_state': 'pending',
    });
    source.items = [item(id: id, priceMinor: 14900)];

    final result = await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    final cached = await readItem(id);
    expect(result.conflictItemIds, contains(id));
    expect(cached['sync_state'], 'conflict');
    expect(cached['is_active'], 0);
    expect(cached['name'], 'Local Edited Name');
    expect(cached['price_minor'], 9000);
  });

  test('quarantines local-only catalog rows in a cloud branch', () async {
    final id = const Uuid().v4();
    final db = await database.open();
    await db.insert('catalog_items', <String, Object?>{
      'id': id,
      'organization_id': organizationId,
      'branch_id': branchId,
      'name': 'Local-only sample',
      'sku': 'LOCAL-SAMPLE-001',
      'category_name': 'Demo',
      'price_minor': 1000,
      'currency_code': 'PHP',
      'is_active': 1,
      'updated_at': now.toIso8601String(),
      'sync_state': 'local',
    });
    source.items = <Map<String, Object?>>[];

    final result = await repository.syncBranch(
      organizationId: organizationId,
      branchId: branchId,
    );

    final cached = await readItem(id);
    expect(result.conflictItemIds, contains(id));
    expect(cached['sync_state'], 'conflict');
    expect(cached['is_active'], 0);
  });

  test('rejects foreign-branch rows before changing the cache', () async {
    source.items = [item(branch: const Uuid().v4())];

    await expectLater(
      repository.syncBranch(
        organizationId: organizationId,
        branchId: branchId,
      ),
      throwsFormatException,
    );
    expect(await (await database.open()).query('catalog_items'), isEmpty);
  });

  test('rejects malformed catalog before partial updates', () async {
    source.items = [
      item(name: 'Valid row'),
      item(currencyCode: 'usd'),
    ];

    await expectLater(
      repository.syncBranch(
        organizationId: organizationId,
        branchId: branchId,
      ),
      throwsFormatException,
    );
    expect(await (await database.open()).query('catalog_items'), isEmpty);
  });

  test('Supabase source does not read without an authenticated session', () async {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test-publishable-key',
    );
    final cloudSource = SupabaseCloudCatalogSource(client: client);

    await expectLater(
      cloudSource.fetchBranchItems(
        organizationId: organizationId,
        branchId: branchId,
      ),
      throwsStateError,
    );
  });
}

Future<bool> _allowBranchAccess({
  required String organizationId,
  required String branchId,
}) async => true;

Future<bool> _denyBranchAccess({
  required String organizationId,
  required String branchId,
}) async => false;

class _FakeCloudCatalogSource implements CloudCatalogSource {
  List<Map<String, Object?>> items = <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> fetchBranchItems({
    required String organizationId,
    required String branchId,
  }) async => items
      .map((item) => Map<String, Object?>.from(item))
      .toList(growable: false);
}

class _CountingCloudCatalogSource implements CloudCatalogSource {
  _CountingCloudCatalogSource({required this.onFetch});

  final void Function() onFetch;

  @override
  Future<List<Map<String, Object?>>> fetchBranchItems({
    required String organizationId,
    required String branchId,
  }) async {
    onFetch();
    return const <Map<String, Object?>>[];
  }
}
