import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/orders/data/order_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late MizzyDatabase database;
  late OrderRepository repository;
  late String organizationId;
  late String branchId;

  setUp(() {
    database = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: 'mizzy-test-${const Uuid().v4()}.db',
    );
    repository = OrderRepository(database: database);
    organizationId = const Uuid().v4();
    branchId = const Uuid().v4();
  });

  tearDown(() async {
    await database.close();
  });

  CreateOrderDraft draft({
    required String orderId,
    required String idempotencyKey,
    MizzyOrderType orderType = MizzyOrderType.takeaway,
    String? tableId,
  }) {
    return CreateOrderDraft(
      orderId: orderId,
      idempotencyKey: idempotencyKey,
      organizationId: organizationId,
      branchId: branchId,
      orderType: orderType,
      tableId: tableId,
      lines: const [
        OrderLineDraft(
          itemName: 'Chicken Adobo',
          quantityMilli: 2000,
          unitPriceMinor: 14900,
        ),
        OrderLineDraft(
          itemName: 'Steamed Rice',
          quantityMilli: 1000,
          unitPriceMinor: 2500,
        ),
      ],
    );
  }

  test('dine-in orders require a table before persistence', () async {
    await expectLater(
      repository.saveOrder(
        draft(
          orderId: const Uuid().v4(),
          idempotencyKey: const Uuid().v4(),
          orderType: MizzyOrderType.dineIn,
        ),
      ),
      throwsArgumentError,
    );
    expect(
      await repository.listOrders(
        organizationId: organizationId,
        branchId: branchId,
      ),
      isEmpty,
    );
  });

  test('takeaway orders cannot be assigned to a table', () async {
    await expectLater(
      repository.saveOrder(
        draft(
          orderId: const Uuid().v4(),
          idempotencyKey: const Uuid().v4(),
          tableId: const Uuid().v4(),
        ),
      ),
      throwsArgumentError,
    );
    expect(
      await repository.listOrders(
        organizationId: organizationId,
        branchId: branchId,
      ),
      isEmpty,
    );
  });

  test('saving an order creates one order and one linked kitchen ticket', () async {
    final orderId = const Uuid().v4();
    final saved = await repository.saveOrder(
      draft(orderId: orderId, idempotencyKey: const Uuid().v4()),
    );

    final orders = await repository.listOrders(
      organizationId: organizationId,
      branchId: branchId,
    );
    final order = await repository.readOrder(
      organizationId: organizationId,
      branchId: branchId,
      orderId: orderId,
    );

    expect(saved.alreadySaved, isFalse);
    expect(orders, hasLength(1));
    expect(order?['total_minor'], 32300);
    expect((order?['lines']! as List), hasLength(2));
    expect((order?['kitchenTicket'] as Map?)?['status'], 'queued');
  });

  test('retrying the same idempotency key does not duplicate an order', () async {
    final orderId = const Uuid().v4();
    final key = const Uuid().v4();
    final first = await repository.saveOrder(
      draft(orderId: orderId, idempotencyKey: key),
    );
    final retry = await repository.saveOrder(
      draft(orderId: orderId, idempotencyKey: key),
    );

    final orders = await repository.listOrders(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(first.alreadySaved, isFalse);
    expect(retry.alreadySaved, isTrue);
    expect(retry.orderId, first.orderId);
    expect(orders, hasLength(1));
  });

  test('an idempotency key cannot be reused for a different order ID', () async {
    final key = const Uuid().v4();
    await repository.saveOrder(
      draft(orderId: const Uuid().v4(), idempotencyKey: key),
    );

    await expectLater(
      repository.saveOrder(
        draft(orderId: const Uuid().v4(), idempotencyKey: key),
      ),
      throwsStateError,
    );

    final orders = await repository.listOrders(
      organizationId: organizationId,
      branchId: branchId,
    );
    expect(orders, hasLength(1));
  });

  test('Kitchen status changes are reflected in the same Orders record', () async {
    final orderId = const Uuid().v4();
    await repository.saveOrder(
      draft(orderId: orderId, idempotencyKey: const Uuid().v4()),
    );

    await repository.updateKitchenStatus(
      organizationId: organizationId,
      branchId: branchId,
      orderId: orderId,
      nextStatus: KitchenTicketStatus.preparing,
    );

    final orders = await repository.listOrders(
      organizationId: organizationId,
      branchId: branchId,
    );
    final order = await repository.readOrder(
      organizationId: organizationId,
      branchId: branchId,
      orderId: orderId,
    );

    expect(orders, hasLength(1));
    expect(orders.single['status'], 'preparing');
    expect((order?['kitchenTicket'] as Map?)?['status'], 'preparing');
  });

  test('invalid Kitchen status transitions are rejected', () async {
    final orderId = const Uuid().v4();
    await repository.saveOrder(
      draft(orderId: orderId, idempotencyKey: const Uuid().v4()),
    );

    await expectLater(
      repository.updateKitchenStatus(
        organizationId: organizationId,
        branchId: branchId,
        orderId: orderId,
        nextStatus: KitchenTicketStatus.served,
      ),
      throwsStateError,
    );

    final order = await repository.readOrder(
      organizationId: organizationId,
      branchId: branchId,
      orderId: orderId,
    );
    expect(order?['status'], 'saved');
  });

  test('orders are visible only within their organization and branch', () async {
    final orderId = const Uuid().v4();
    await repository.saveOrder(
      draft(orderId: orderId, idempotencyKey: const Uuid().v4()),
    );

    final differentBranch = const Uuid().v4();
    final differentOrganization = const Uuid().v4();

    expect(
      await repository.listOrders(
        organizationId: organizationId,
        branchId: differentBranch,
      ),
      isEmpty,
    );
    expect(
      await repository.listOrders(
        organizationId: differentOrganization,
        branchId: branchId,
      ),
      isEmpty,
    );
    expect(
      await repository.readOrder(
        organizationId: organizationId,
        branchId: differentBranch,
        orderId: orderId,
      ),
      isNull,
    );
    expect(
      await repository.readOrder(
        organizationId: differentOrganization,
        branchId: branchId,
        orderId: orderId,
      ),
      isNull,
    );
  });

  test('simultaneous retries create one order and one kitchen ticket', () async {
    final orderId = const Uuid().v4();
    final idempotencyKey = const Uuid().v4();

    final results = await Future.wait([
      repository.saveOrder(
        draft(orderId: orderId, idempotencyKey: idempotencyKey),
      ),
      repository.saveOrder(
        draft(orderId: orderId, idempotencyKey: idempotencyKey),
      ),
    ]);

    final orders = await repository.listOrders(
      organizationId: organizationId,
      branchId: branchId,
    );
    final rawDatabase = await database.open();
    final tickets = await rawDatabase.query(
      'kitchen_tickets',
      where: 'order_id = ?',
      whereArgs: [orderId],
    );
    final outboxEvents = await rawDatabase.query(
      'sync_outbox',
      where: 'entity_id = ? OR idempotency_key IN (?, ?)',
      whereArgs: [orderId, 'order:$idempotencyKey', 'kitchen:$idempotencyKey'],
    );

    expect(results.map((result) => result.orderId).toSet(), {orderId});
    expect(results.where((result) => result.alreadySaved), hasLength(1));
    expect(results.where((result) => !result.alreadySaved), hasLength(1));
    expect(orders, hasLength(1));
    expect(tickets, hasLength(1));
    expect(outboxEvents, hasLength(2));
  });
}
