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
      await database.close();
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

      await tester.tap(find.text('Tables'));
      await tester.pumpAndSettle();
      expect(find.text('OCCUPIED'), findsOneWidget);
      expect(find.text('Use table'), findsNWidgets(7));

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
