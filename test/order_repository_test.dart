import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/orders/data/order_repository.dart';

void main() {
  late MizzyDatabase localDatabase;
  late OrderRepository repository;
  late Database rawDatabase;
  late String databasePath;

  setUpAll(() {
    sqfliteFfiInit();
  });

  setUp(() async {
    final name = 'mizzy_test_${DateTime.now().microsecondsSinceEpoch}.db';
    databasePath = p.join(await databaseFactoryFfi.getDatabasesPath(), name);
    await databaseFactoryFfi.deleteDatabase(databasePath);
    localDatabase = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: name,
    );
    repository = OrderRepository(database: localDatabase);
    rawDatabase = await localDatabase.open();
  });

  tearDown(() async {
    await localDatabase.close();
    await databaseFactoryFfi.deleteDatabase(databasePath);
  });

  test('creates versioned schema, enables foreign keys and persists device ID',
      () async {
    final foreignKeys = await rawDatabase.rawQuery('PRAGMA foreign_keys');
    expect(foreignKeys.single['foreign_keys'], 1);

    final tables = await rawDatabase.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = tables.map((row) => row['name']).toSet();
    expect(names, containsAll(<String>[
      'local_meta',
      'orders',
      'order_lines',
      'kitchen_tickets',
      'payments',
      'inventory_movements',
      'sync_outbox',
      'sync_cursors',
    ]));

    final firstId = await localDatabase.installationId();
    final secondId = await localDatabase.installationId();
    expect(Uuid.isValidUUIDFormat(fromString: firstId), isTrue);
    expect(secondId, firstId);
  });

  test('saves one logical order to Orders and Kitchen in one transaction',
      () async {
    final draft = _draft();
    final result = await repository.saveOrder(draft);

    expect(result.alreadySaved, isFalse);
    expect(result.localOrderNumber, 1);
    final order = await repository.readOrder(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
    );

    expect(order, isNotNull);
    expect(order!['status'], 'saved');
    expect(order['subtotal_minor'], 3000);
    expect(order['discount_minor'], 100);
    expect(order['tax_minor'], 50);
    expect(order['total_minor'], 2950);
    expect((order['lines']! as List<Map<String, Object?>>).length, 2);

    final ticket = order['kitchenTicket']! as Map<String, Object?>;
    expect(ticket['order_id'], draft.orderId);
    expect(ticket['status'], 'queued');

    final outboxCount = await rawDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM sync_outbox',
    );
    expect(outboxCount.single['count'], 2);

    final wrongBranch = await repository.readOrder(
      organizationId: draft.organizationId,
      branchId: const Uuid().v4(),
      orderId: draft.orderId,
    );
    expect(wrongBranch, isNull);
  });

  test('replaying the same idempotency key does not duplicate an order',
      () async {
    final draft = _draft();
    final first = await repository.saveOrder(draft);
    final replay = await repository.saveOrder(draft);

    expect(replay.alreadySaved, isTrue);
    expect(replay.orderId, first.orderId);
    expect(replay.localOrderNumber, first.localOrderNumber);

    final orderCount = await rawDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM orders',
    );
    final lineCount = await rawDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM order_lines',
    );
    final ticketCount = await rawDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM kitchen_tickets',
    );
    final outboxCount = await rawDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM sync_outbox',
    );
    expect(orderCount.single['count'], 1);
    expect(lineCount.single['count'], 2);
    expect(ticketCount.single['count'], 1);
    expect(outboxCount.single['count'], 2);
  });

  test('rejects reuse of an idempotency key for different order contents',
      () async {
    final original = _draft();
    await repository.saveOrder(original);

    final changed = CreateOrderDraft(
      orderId: const Uuid().v4(),
      idempotencyKey: original.idempotencyKey,
      organizationId: original.organizationId,
      branchId: original.branchId,
      orderType: original.orderType,
      currencyCode: original.currencyCode,
      note: 'different payload',
      lines: const <OrderLineDraft>[
        OrderLineDraft(
          itemName: 'Different item',
          quantityMilli: 1000,
          unitPriceMinor: 100,
        ),
      ],
    );

    await expectLater(repository.saveOrder(changed), throwsA(isA<StateError>()));
  });

  test('kitchen transitions update the ticket and parent order together',
      () async {
    final draft = _draft();
    await repository.saveOrder(draft);

    await repository.updateKitchenStatus(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
      nextStatus: KitchenTicketStatus.preparing,
    );
    await repository.updateKitchenStatus(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
      nextStatus: KitchenTicketStatus.ready,
    );

    final readyOrder = await repository.readOrder(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
    );
    expect(readyOrder!['status'], 'ready');
    expect(
      (readyOrder['kitchenTicket']! as Map<String, Object?>)['status'],
      'ready',
    );

    await repository.updateKitchenStatus(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
      nextStatus: KitchenTicketStatus.served,
    );
    final servedOrder = await repository.readOrder(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
    );
    expect(servedOrder!['status'], 'served');
    expect(
      (servedOrder['kitchenTicket']! as Map<String, Object?>)['status'],
      'served',
    );

    final eventCount = await rawDatabase.rawQuery(
      'SELECT COUNT(*) AS count FROM sync_outbox',
    );
    expect(eventCount.single['count'], 5);
  });

  test('rejects invalid kitchen transitions without changing either status',
      () async {
    final draft = _draft();
    await repository.saveOrder(draft);

    await expectLater(
      repository.updateKitchenStatus(
        organizationId: draft.organizationId,
        branchId: draft.branchId,
        orderId: draft.orderId,
        nextStatus: KitchenTicketStatus.ready,
      ),
      throwsA(isA<StateError>()),
    );

    final order = await repository.readOrder(
      organizationId: draft.organizationId,
      branchId: draft.branchId,
      orderId: draft.orderId,
    );
    expect(order!['status'], 'saved');
    expect(
      (order['kitchenTicket']! as Map<String, Object?>)['status'],
      'queued',
    );
  });

  test('a failed order insert leaves no partial order, ticket or outbox',
      () async {
    final draft = CreateOrderDraft(
      orderId: const Uuid().v4(),
      idempotencyKey: const Uuid().v4(),
      organizationId: const Uuid().v4(),
      branchId: const Uuid().v4(),
      orderType: MizzyOrderType.dineIn,
      tableId: const Uuid().v4(),
      lines: const <OrderLineDraft>[
        OrderLineDraft(
          itemName: 'Coffee',
          quantityMilli: 1000,
          unitPriceMinor: 150,
        ),
      ],
    );

    await expectLater(
      repository.saveOrder(draft),
      throwsA(isA<DatabaseException>()),
    );

    for (final tableName in <String>['orders', 'order_lines', 'kitchen_tickets', 'sync_outbox']) {
      final rows = await rawDatabase.rawQuery(
        'SELECT COUNT(*) AS count FROM $tableName',
      );
      expect(rows.single['count'], 0, reason: '$tableName should roll back');
    }
  });
}

CreateOrderDraft _draft() {
  return CreateOrderDraft(
    orderId: const Uuid().v4(),
    idempotencyKey: const Uuid().v4(),
    organizationId: const Uuid().v4(),
    branchId: const Uuid().v4(),
    orderType: MizzyOrderType.takeaway,
    lines: const <OrderLineDraft>[
      OrderLineDraft(
        itemName: 'Noodle Bowl',
        quantityMilli: 2000,
        unitPriceMinor: 1250,
      ),
      OrderLineDraft(
        itemName: 'Iced Tea',
        quantityMilli: 1000,
        unitPriceMinor: 500,
        discountMinor: 100,
        taxMinor: 50,
      ),
    ],
  );
}
