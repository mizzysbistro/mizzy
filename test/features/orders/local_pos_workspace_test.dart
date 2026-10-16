import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/orders/presentation/local_pos_workspace.dart';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < timeout) {
    await tester.pump(const Duration(milliseconds: 16));
    if (finder.evaluate().isNotEmpty) return;

    // SQLite FFI performs real asynchronous work. Allow the real event loop
    // to finish between fake-time widget frames while the UI is loading.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }
  fail('Timed out waiting for $finder');
}

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
      await _pumpUntilFound(tester, find.text('Chicken Adobo'));

      expect(find.text('Chicken Adobo'), findsOneWidget);
      await tester.tap(find.byTooltip('Add Chicken Adobo'));
      await tester.pump();

      await tester.tap(find.text('Save & send to Kitchen'));
      await _pumpUntilFound(tester, find.text('Order #1'));

      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('SAVED · takeaway'), findsOneWidget);

      await tester.tap(find.text('Kitchen'));
      await _pumpUntilFound(tester, find.text('SAVED · takeaway'));
      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('SAVED · takeaway'), findsOneWidget);

      await tester.tap(find.text('Start'));
      await _pumpUntilFound(tester, find.text('PREPARING · takeaway'));
      expect(find.text('PREPARING · takeaway'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await _pumpUntilFound(tester, find.text('PREPARING · takeaway'));
      expect(find.text('Order #1'), findsOneWidget);
      expect(find.text('PREPARING · takeaway'), findsOneWidget);

      final rawDatabase = await database.open();
      expect(await rawDatabase.query('orders'), hasLength(1));
      expect(await rawDatabase.query('kitchen_tickets'), hasLength(1));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('table layout assigns one dine-in table to the saved order', (
    tester,
  ) async {
    final database = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: 'mizzy-table-widget-${const Uuid().v4()}.db',
    );
    addTearDown(database.close);

    await tester.pumpWidget(
      MaterialApp(home: LocalPosWorkspace(database: database)),
    );
    await _pumpUntilFound(tester, find.text('Chicken Adobo'));

    await tester.tap(find.text('Tables'));
    await _pumpUntilFound(tester, find.text('Use table'));
    expect(find.text('Use table'), findsNWidgets(8));

    await tester.tap(find.text('Use table').first);
    await _pumpUntilFound(tester, find.text('Dine-in'));
    expect(find.text('Dine-in'), findsOneWidget);
    expect(find.text('Table: T1'), findsOneWidget);

    await tester.tap(find.byTooltip('Add Chicken Adobo'));
    await tester.pump();
    await tester.tap(find.text('Save & send to Kitchen'));
    await _pumpUntilFound(tester, find.text('Order #1'));

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
    await _pumpUntilFound(tester, find.text('OCCUPIED'));
    expect(find.text('OCCUPIED'), findsOneWidget);
    expect(find.text('Use table'), findsNWidgets(7));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
