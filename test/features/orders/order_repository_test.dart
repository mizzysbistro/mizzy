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
  }) {
    return CreateOrderDraft(
      orderId: orderId,
      idempotencyKey: idempotencyKey,
      organizationId: organizationId,
      branchId: branchId,
      orderType: MizzyOrderType.takeaway,
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
}
