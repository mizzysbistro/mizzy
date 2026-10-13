import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/orders/data/order_repository.dart';
import 'package:mizzy/features/sync/data/sync_outbox_repository.dart';
import 'package:mizzy/features/sync/data/supabase_sync_worker.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late MizzyDatabase database;
  late SyncOutboxRepository outbox;
  late _FakeCloudSyncTransport transport;
  late AuthenticatedOutboxSyncWorker worker;
  late String organizationId;
  late String branchId;
  late String catalogItemId;
  late String orderId;
  late String orderIdempotencyKey;
  late DateTime now;
  var accessAllowed = true;
  var allowKitchenTransition = true;

  setUp(() async {
    now = DateTime.utc(2026, 10, 14, 12);
    organizationId = const Uuid().v4();
    branchId = const Uuid().v4();
    catalogItemId = const Uuid().v4();
    orderId = const Uuid().v4();
    orderIdempotencyKey = const Uuid().v4();
    database = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: 'mizzy-sync-worker-${const Uuid().v4()}.db',
    );
    final db = await database.open();
    await db.insert('catalog_items', <String, Object?>{
      'id': catalogItemId,
      'organization_id': organizationId,
      'branch_id': branchId,
      'name': 'Cloud Adobo',
      'sku': 'CLOUD-ADOB-001',
      'category_name': 'Meals',
      'price_minor': 14900,
      'currency_code': 'PHP',
      'is_active': 1,
      'updated_at': now.toIso8601String(),
      'sync_state': 'synced',
    });
    outbox = SyncOutboxRepository(database: database, clock: () => now);
    transport = _FakeCloudSyncTransport();
    worker = AuthenticatedOutboxSyncWorker(
      database: database,
      outbox: outbox,
      transport: transport,
      hasBranchAccess: ({
        required String organizationId,
        required String branchId,
      }) async => accessAllowed,
      hasEventPermission: ({
        required String organizationId,
        required String branchId,
        required String entityType,
        required String operation,
      }) async {
        if (entityType == 'kitchen_ticket' && operation == 'transition') {
          return allowKitchenTransition;
        }
        return true;
      },
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<void> createOrder({bool addKitchenTransition = false}) async {
    final orders = OrderRepository(database: database);
    await orders.saveOrder(
      CreateOrderDraft(
        orderId: orderId,
        idempotencyKey: orderIdempotencyKey,
        organizationId: organizationId,
        branchId: branchId,
        orderType: MizzyOrderType.takeaway,
        lines: <OrderLineDraft>[
          OrderLineDraft(
            catalogItemId: catalogItemId,
            itemName: 'Cloud Adobo',
            sku: 'CLOUD-ADOB-001',
            quantityMilli: 1000,
            unitPriceMinor: 14900,
          ),
        ],
      ),
    );
    final db = await database.open();
    final ticket = (await db.query(
      'kitchen_tickets',
      where: 'order_id = ? AND organization_id = ? AND branch_id = ?',
      whereArgs: <Object?>[orderId, organizationId, branchId],
      limit: 1,
    )).single;
    transport.ticket = <String, Object?>{
      'id': ticket['id'],
      'organization_id': organizationId,
      'branch_id': branchId,
      'order_id': orderId,
      'status': 'queued',
    };
    if (addKitchenTransition) {
      await orders.updateKitchenStatus(
        organizationId: organizationId,
        branchId: branchId,
        orderId: orderId,
        nextStatus: KitchenTicketStatus.preparing,
      );
      transport.ticket!['status'] = 'queued';
    }
  }

  test('does not claim outbox events without an authenticated session', () async {
    await createOrder();
    transport.hasSession = false;

    final result = await worker.syncOnce(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.status, SyncCycleStatus.authenticationRequired);
    expect(result.claimed, 0);
    expect(transport.calls, isEmpty);
    final rows = await (await database.open()).query('sync_outbox');
    expect(rows.map((row) => row['status']).toSet(), {'pending'});
    expect(rows.map((row) => row['attempts']).toSet(), {0});
  });

  test('does not claim outbox events when active branch access is denied', () async {
    await createOrder();
    accessAllowed = false;

    final result = await worker.syncOnce(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.status, SyncCycleStatus.branchAccessDenied);
    expect(result.claimed, 0);
    expect(transport.calls, isEmpty);
    final rows = await (await database.open()).query('sync_outbox');
    expect(rows.map((row) => row['status']).toSet(), {'pending'});
  });

  test(
    'does not quarantine a Kitchen event when the current actor lacks Kitchen role',
    () async {
      await createOrder(addKitchenTransition: true);
      allowKitchenTransition = false;

      final result = await worker.syncOnce(
        organizationId: organizationId,
        branchId: branchId,
      );

      expect(result.claimed, 3);
      expect(result.delivered, 2);
      expect(result.retried, 1);
      expect(result.conflicts, 0);
      expect(
        transport.calls,
        ['save_order', 'save_order'],
      );

      final rows = await (await database.open()).query(
        'sync_outbox',
        orderBy: 'created_at ASC, rowid ASC',
      );
      expect(rows.last['status'], 'failed');
      expect(rows.last['last_error'], 'role_not_permitted');
    },
  );

  test(
    'uploads order, verifies the server-created ticket and applies Kitchen transition in dependency order',
    () async {
      await createOrder(addKitchenTransition: true);

      final result = await worker.syncOnce(
        organizationId: organizationId,
        branchId: branchId,
      );

      expect(result.status, SyncCycleStatus.completed);
      expect(result.claimed, 3);
      expect(result.delivered, 3);
      expect(result.retried, 0);
      expect(result.conflicts, 0);
      expect(
        transport.calls,
        [
          'save_order',
          'save_order',
          'apply_kitchen_transition_event',
        ],
      );
      expect(
        transport.lastOrderParameters!['p_idempotency_key'],
        orderIdempotencyKey,
      );
      final remoteLines =
          transport.lastOrderParameters!['p_lines'] as List<Object?>;
      final remoteLine = remoteLines.single! as Map;
      expect(remoteLine['catalogItemId'], catalogItemId);
      expect(remoteLine['unitPriceMinor'], 14900);
      expect(remoteLine.containsKey('catalog_item_id'), isFalse);

      final db = await database.open();
      final outboxRows = await db.query('sync_outbox');
      expect(outboxRows.map((row) => row['status']).toSet(), {'done'});
      final order = (await db.query(
        'orders',
        where: 'id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, organizationId, branchId],
        limit: 1,
      )).single;
      final ticket = (await db.query(
        'kitchen_tickets',
        where: 'order_id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, organizationId, branchId],
        limit: 1,
      )).single;
      expect(order['status'], 'preparing');
      expect(order['sync_state'], 'synced');
      expect(ticket['status'], 'preparing');
      expect(ticket['sync_state'], 'synced');
    },
  );

  test('permanent server rejection quarantines the parent and blocks children', () async {
    await createOrder();
    transport.orderFailure = const SyncRemoteFailure.permanent();

    final result = await worker.syncOnce(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.conflicts, 1);
    expect(result.delivered, 0);
    expect(transport.calls, ['save_order']);
    final rows = await (await database.open()).query(
      'sync_outbox',
      orderBy: 'created_at ASC, rowid ASC',
    );
    expect(rows.first['status'], 'conflict');
    expect(rows.first['last_error'], 'rejected_by_server');
    expect(rows.last['status'], 'pending');
  });

  test('transient failure uses safe backoff without claiming child event', () async {
    await createOrder();
    transport.orderFailure = const SyncRemoteFailure.retryable(
      SyncFailureCode.timeout,
    );

    final result = await worker.syncOnce(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.retried, 1);
    expect(result.conflicts, 0);
    expect(transport.calls, ['save_order']);
    final rows = await (await database.open()).query(
      'sync_outbox',
      orderBy: 'created_at ASC, rowid ASC',
    );
    expect(rows.first['status'], 'failed');
    expect(rows.first['last_error'], 'timeout');
    expect(rows.last['status'], 'pending');
  });

  test('malformed outbox payload is quarantined without a network write', () async {
    await createOrder();
    final db = await database.open();
    await db.update(
      'sync_outbox',
      <String, Object?>{'payload_json': '{'},
      where: 'entity_type = ? AND operation = ?',
      whereArgs: <Object?>['order', 'create'],
    );

    final result = await worker.syncOnce(
      organizationId: organizationId,
      branchId: branchId,
    );

    expect(result.conflicts, 1);
    expect(transport.calls, isEmpty);
    final rows = await db.query(
      'sync_outbox',
      orderBy: 'created_at ASC, rowid ASC',
    );
    expect(rows.first['status'], 'conflict');
    expect(rows.first['last_error'], 'rejected_by_server');
  });
}

class _FakeCloudSyncTransport implements CloudSyncTransport {
  @override
  bool hasSession = true;

  final List<String> calls = <String>[];
  Map<String, Object?>? ticket;
  Map<String, Object?>? lastOrderParameters;
  SyncRemoteFailure? orderFailure;
  int saveOrderCalls = 0;

  @override
  Future<Map<String, Object?>> saveOrder({
    required Map<String, Object?> parameters,
  }) async {
    calls.add('save_order');
    saveOrderCalls++;
    lastOrderParameters = parameters;
    final failure = orderFailure;
    if (failure != null) throw failure;

    final lines = parameters['p_lines']! as List<Object?>;
    var totalMinor = 0;
    for (final rawLine in lines) {
      final line = rawLine! as Map;
      totalMinor +=
          ((line['unitPriceMinor'] as int) *
                  (line['quantityMilli'] as int) /
                  1000)
              .round();
    }
    return <String, Object?>{
      'order_id': parameters['p_order_id'],
      'order_status': 'saved',
      'local_order_number': parameters['p_local_order_number'],
      'total_minor': totalMinor,
      'currency_code': 'PHP',
      'kitchen_ticket_id': parameters['p_kitchen_ticket_id'],
      'already_saved': saveOrderCalls > 1,
    };
  }

  @override
  Future<Map<String, Object?>> applyKitchenTransition({
    required Map<String, Object?> parameters,
  }) async {
    calls.add('apply_kitchen_transition_event');
    final current = ticket!;
    current['status'] = parameters['p_next_status'];
    return <String, Object?>{
      'ticket_id': parameters['p_ticket_id'],
      'order_id': current['order_id'],
      'ticket_status': parameters['p_next_status'],
      'order_status': parameters['p_next_status'],
      'updated_at': DateTime.utc(2026, 10, 14, 12).toIso8601String(),
      'already_applied': false,
    };
  }
}
