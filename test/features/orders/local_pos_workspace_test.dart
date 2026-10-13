import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/orders/presentation/local_pos_workspace.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  testWidgets(
    'Counter save appears in Orders and Kitchen with one shared status',
    (tester) async {
      final database = MizzyDatabase(
        factory: databaseFactoryFfi,
        databaseName: 'mizzy-pos-widget-${const Uuid().v4()}.db',
      );
      addTearDown(database.close);

      await tester.pumpWidget(
        MaterialApp(home: LocalPosWorkspace(database: database)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Chicken Adobo'), findsOneWidget);
      await tester.tap(find.byTooltip('Add Chicken Adobo'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save & send to Kitchen'));
      await tester.pumpAndSettle();

      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('SAVED · takeaway'), findsOneWidget);

      await tester.tap(find.text('Kitchen'));
      await tester.pumpAndSettle();
      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('SAVED · takeaway'), findsOneWidget);

      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(find.text('PREPARING · takeaway'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pumpAndSettle();
      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('PREPARING · takeaway'), findsOneWidget);

      final rawDatabase = await database.open();
      expect(await rawDatabase.query('orders'), hasLength(1));
      expect(await rawDatabase.query('kitchen_tickets'), hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'selected cloud branch loads its catalog and never seeds demo data',
    (tester) async {
      final database = MizzyDatabase(
        factory: databaseFactoryFfi,
        databaseName: 'mizzy-cloud-branch-${const Uuid().v4()}.db',
      );
      addTearDown(database.close);
      final organizationId = const Uuid().v4();
      final branchId = const Uuid().v4();
      final catalogId = const Uuid().v4();
      var syncCalls = 0;

      Future<int> refreshCloudCatalog({
        required MizzyDatabase database,
        required String organizationId,
        required String branchId,
      }) async {
        syncCalls++;
        final rawDatabase = await database.open();
        await rawDatabase.insert('catalog_items', <String, Object?>{
          'id': catalogId,
          'organization_id': organizationId,
          'branch_id': branchId,
          'name': 'Cloud Meal',
          'sku': 'CLOUD-MEAL-001',
          'category_name': 'Meals',
          'price_minor': 12500,
          'currency_code': 'PHP',
          'is_active': 1,
          'updated_at': DateTime.utc(2026, 10, 14).toIso8601String(),
          'sync_state': 'synced',
        });
        return 0;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: LocalPosWorkspace(
            database: database,
            organizationId: organizationId,
            branchId: branchId,
            cloudCatalogRefresh: refreshCloudCatalog,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(syncCalls, 1);
      expect(find.text('Cloud Meal'), findsOneWidget);
      expect(find.text('Chicken Adobo'), findsNothing);
      expect(
        find.textContaining('order sync is not enabled'),
        findsOneWidget,
      );

      final rawDatabase = await database.open();
      expect(
        await rawDatabase.query(
          'restaurant_tables',
          where: 'organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[organizationId, branchId],
        ),
        isEmpty,
      );
      expect(await rawDatabase.query('catalog_items'), hasLength(1));

      await tester.tap(find.byTooltip('Add Cloud Meal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save locally to Kitchen'));
      await tester.pumpAndSettle();

      final orders = await rawDatabase.query('orders');
      final lines = await rawDatabase.query('order_lines');
      expect(orders, hasLength(1));
      expect(orders.single['organization_id'], organizationId);
      expect(orders.single['branch_id'], branchId);
      expect(lines.single['catalog_item_id'], catalogId);
      expect(lines.single['item_name_snapshot'], 'Cloud Meal');
      expect(lines.single['unit_price_minor'], 12500);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cloud workspace falls back to cached catalog when refresh fails',
    (tester) async {
      final database = MizzyDatabase(
        factory: databaseFactoryFfi,
        databaseName: 'mizzy-cloud-offline-${const Uuid().v4()}.db',
      );
      addTearDown(database.close);
      final organizationId = const Uuid().v4();
      final branchId = const Uuid().v4();
      final catalogId = const Uuid().v4();
      final rawDatabase = await database.open();
      await rawDatabase.insert('catalog_items', <String, Object?>{
        'id': catalogId,
        'organization_id': organizationId,
        'branch_id': branchId,
        'name': 'Cached Cloud Meal',
        'sku': 'CACHED-MEAL-001',
        'category_name': 'Meals',
        'price_minor': 11000,
        'currency_code': 'PHP',
        'is_active': 1,
        'updated_at': DateTime.utc(2026, 10, 14).toIso8601String(),
        'sync_state': 'synced',
      });
      var refreshCalls = 0;

      Future<int> failCloudRefresh({
        required MizzyDatabase database,
        required String organizationId,
        required String branchId,
      }) async {
        refreshCalls++;
        throw StateError('simulated offline network');
      }

      await tester.pumpWidget(
        MaterialApp(
          home: LocalPosWorkspace(
            database: database,
            organizationId: organizationId,
            branchId: branchId,
            cloudCatalogRefresh: failCloudRefresh,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(refreshCalls, 1);
      expect(find.text('Cached Cloud Meal'), findsOneWidget);
      expect(find.text('Chicken Adobo'), findsNothing);
      expect(
        find.textContaining('Showing any verified catalog cached'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Add Cached Cloud Meal'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save locally to Kitchen'));
      await tester.pumpAndSettle();

      final orders = await rawDatabase.query('orders');
      final lines = await rawDatabase.query('order_lines');
      expect(orders, hasLength(1));
      expect(orders.single['organization_id'], organizationId);
      expect(orders.single['branch_id'], branchId);
      expect(lines.single['catalog_item_id'], catalogId);
      expect(lines.single['unit_price_minor'], 11000);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'table layout assigns one dine-in table to the saved order',
    (tester) async {
      final database = MizzyDatabase(
        factory: databaseFactoryFfi,
        databaseName: 'mizzy-table-widget-${const Uuid().v4()}.db',
      );
      addTearDown(database.close);

      await tester.pumpWidget(
        MaterialApp(home: LocalPosWorkspace(database: database)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Tables'));
      await tester.pumpAndSettle();
      expect(find.text('Use table'), findsNWidgets(8));

      await tester.tap(find.text('Use table').first);
      await tester.pumpAndSettle();
      expect(find.text('Dine-in'), findsOneWidget);
      expect(find.text('Table: T1'), findsOneWidget);

      await tester.tap(find.byTooltip('Add Chicken Adobo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save & send to Kitchen'));
      await tester.pumpAndSettle();

      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('SAVED · dine_in · T1'), findsOneWidget);

      final rawDatabase = await database.open();
      final orders = await rawDatabase.query('orders');
      final tables = await rawDatabase.query(
        'restaurant_tables',
        where: 'name = ?',
        whereArgs: const <Object?>['T1'],
      );
      expect(orders, hasLength(1));
      expect(orders.single['order_type'], 'dine_in');
      expect(orders.single['table_id'], isNotNull);
      expect(tables.single['status'], 'occupied');

      final catalog = await rawDatabase.query(
        'catalog_items',
        where: 'organization_id = ? AND branch_id = ? AND is_active = ?',
        whereArgs: <Object?>[
          orders.single['organization_id'],
          orders.single['branch_id'],
          1,
        ],
      );
      final lines = await rawDatabase.query(
        'order_lines',
        where: 'order_id = ?',
        whereArgs: <Object?>[orders.single['id']],
      );
      expect(catalog, hasLength(6));
      expect(lines, hasLength(1));
      expect(lines.single['catalog_item_id'], isNotNull);
      expect(lines.single['sku_snapshot'], 'MIZ-ADOB-001');
      expect(lines.single['item_name_snapshot'], 'Chicken Adobo');

      await tester.tap(find.text('Tables'));
      await tester.pumpAndSettle();
      expect(find.text('OCCUPIED'), findsOneWidget);
      expect(find.text('Use table'), findsNWidgets(7));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
