import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/mizzy_database.dart';

enum MizzyOrderType {
  dineIn('dine_in'),
  takeaway('takeaway'),
  delivery('delivery');

  const MizzyOrderType(this.storageValue);

  final String storageValue;
}

enum KitchenTicketStatus {
  queued('queued'),
  preparing('preparing'),
  ready('ready'),
  served('served'),
  cancelled('cancelled');

  const KitchenTicketStatus(this.storageValue);

  final String storageValue;

  String get orderStatus => switch (this) {
    KitchenTicketStatus.queued => 'saved',
    KitchenTicketStatus.preparing => 'preparing',
    KitchenTicketStatus.ready => 'ready',
    KitchenTicketStatus.served => 'served',
    KitchenTicketStatus.cancelled => 'cancelled',
  };
}

class OrderLineDraft {
  const OrderLineDraft({
    required this.itemName,
    required this.quantityMilli,
    required this.unitPriceMinor,
    this.catalogItemId,
    this.sku,
    this.discountMinor = 0,
    this.taxMinor = 0,
  });

  final String? catalogItemId;
  final String itemName;
  final String? sku;
  final int quantityMilli;
  final int unitPriceMinor;
  final int discountMinor;
  final int taxMinor;
}

class CreateOrderDraft {
  CreateOrderDraft({
    required this.orderId,
    required this.idempotencyKey,
    required this.organizationId,
    required this.branchId,
    required this.orderType,
    required List<OrderLineDraft> lines,
    this.tableId,
    this.currencyCode = 'PHP',
    this.note,
    this.openedBy,
  }) : lines = List<OrderLineDraft>.unmodifiable(lines);

  /// Generate this once for the logical order and reuse it across a retry.
  final String orderId;

  /// Stable UUID for this save request; never generate a new key for a retry.
  final String idempotencyKey;
  final String organizationId;
  final String branchId;
  final MizzyOrderType orderType;
  final List<OrderLineDraft> lines;
  final String? tableId;
  final String currencyCode;
  final String? note;
  final String? openedBy;
}

class SaveOrderResult {
  const SaveOrderResult({
    required this.orderId,
    required this.localOrderNumber,
    required this.deviceId,
    required this.alreadySaved,
  });

  final String orderId;
  final int localOrderNumber;
  final String deviceId;
  final bool alreadySaved;
}

class OrderRepository {
  OrderRepository({
    required MizzyDatabase database,
    Uuid? uuid,
    DateTime Function()? clock,
  }) : _database = database,
       _uuid = uuid ?? const Uuid(),
       _clock = clock ?? DateTime.now;

  final MizzyDatabase _database;
  final Uuid _uuid;
  final DateTime Function() _clock;

  static final BigInt _maxSqlInteger = BigInt.parse('9223372036854775807');

  static const Map<KitchenTicketStatus, Set<KitchenTicketStatus>>
  _allowedKitchenTransitions = <KitchenTicketStatus, Set<KitchenTicketStatus>>{
    KitchenTicketStatus.queued: <KitchenTicketStatus>{
      KitchenTicketStatus.preparing,
      KitchenTicketStatus.cancelled,
    },
    KitchenTicketStatus.preparing: <KitchenTicketStatus>{
      KitchenTicketStatus.ready,
      KitchenTicketStatus.cancelled,
    },
    KitchenTicketStatus.ready: <KitchenTicketStatus>{
      KitchenTicketStatus.preparing,
      KitchenTicketStatus.served,
    },
    KitchenTicketStatus.served: <KitchenTicketStatus>{},
    KitchenTicketStatus.cancelled: <KitchenTicketStatus>{},
  };

  Future<SaveOrderResult> saveOrder(CreateOrderDraft draft) async {
    _validateDraft(draft);
    final computedLines = draft.lines.map(_computeLine).toList(growable: false);
    final subtotal = _sumAmounts(
      computedLines.map((line) => line.subtotalMinor),
      'subtotal',
    );
    final discount = _sumAmounts(
      computedLines.map((line) => line.discountMinor),
      'discount',
    );
    final tax = _sumAmounts(computedLines.map((line) => line.taxMinor), 'tax');
    final total = _checkedAmount(
      BigInt.from(subtotal) - BigInt.from(discount) + BigInt.from(tax),
      'order total',
    );
    final fingerprint = _fingerprint(draft, computedLines);
    final deviceId = await _database.installationId();
    final database = await _database.open();

    return database.transaction((transaction) async {
      final matchingKey = await transaction.query(
        'orders',
        columns: <String>[
          'id',
          'local_order_number',
          'device_id',
          'request_fingerprint',
        ],
        where: 'idempotency_key = ?',
        whereArgs: <Object?>[draft.idempotencyKey],
        limit: 1,
      );
      if (matchingKey.isNotEmpty) {
        final existing = matchingKey.single;
        if (existing['request_fingerprint'] != fingerprint) {
          throw StateError(
            'This idempotency key was already used for a different order payload.',
          );
        }
        return SaveOrderResult(
          orderId: existing['id']! as String,
          localOrderNumber: existing['local_order_number']! as int,
          deviceId: existing['device_id']! as String,
          alreadySaved: true,
        );
      }

      final duplicateOrderId = await transaction.query(
        'orders',
        columns: <String>['id'],
        where: 'id = ?',
        whereArgs: <Object?>[draft.orderId],
        limit: 1,
      );
      if (duplicateOrderId.isNotEmpty) {
        throw StateError(
          'This order ID already exists under another idempotency key.',
        );
      }

      final numberRows = await transaction.rawQuery(
        'SELECT COALESCE(MAX(local_order_number), 0) + 1 AS next_number '
        'FROM orders WHERE organization_id = ? AND branch_id = ? AND device_id = ?',
        <Object?>[draft.organizationId, draft.branchId, deviceId],
      );
      final localOrderNumber = numberRows.single['next_number']! as int;
      final timestamp = _timestamp();
      final ticketId = _uuid.v4();

      await transaction.insert('orders', <String, Object?>{
        'id': draft.orderId,
        'organization_id': draft.organizationId,
        'branch_id': draft.branchId,
        'local_order_number': localOrderNumber,
        'device_id': deviceId,
        'status': 'saved',
        'order_type': draft.orderType.storageValue,
        'table_id': draft.tableId,
        'subtotal_minor': subtotal,
        'tax_minor': tax,
        'discount_minor': discount,
        'total_minor': total,
        'currency_code': draft.currencyCode,
        'note': _trimOrNull(draft.note),
        'opened_by': draft.openedBy,
        'created_at': timestamp,
        'updated_at': timestamp,
        'sync_state': 'pending',
        'server_version': 0,
        'idempotency_key': draft.idempotencyKey,
        'request_fingerprint': fingerprint,
      });

      final persistedLines = <Map<String, Object?>>[];
      for (final computedLine in computedLines) {
        final lineId = _uuid.v4();
        final input = computedLine.input;
        final row = <String, Object?>{
          'id': lineId,
          'order_id': draft.orderId,
          'catalog_item_id': input.catalogItemId,
          'item_name_snapshot': input.itemName.trim(),
          'sku_snapshot': _trimOrNull(input.sku),
          'quantity_milli': input.quantityMilli,
          'unit_price_minor': input.unitPriceMinor,
          'discount_minor': input.discountMinor,
          'tax_minor': input.taxMinor,
          'line_total_minor': computedLine.lineTotalMinor,
          'created_at': timestamp,
        };
        await transaction.insert('order_lines', row);
        persistedLines.add(row);
      }

      await transaction.insert('kitchen_tickets', <String, Object?>{
        'id': ticketId,
        'organization_id': draft.organizationId,
        'branch_id': draft.branchId,
        'order_id': draft.orderId,
        'status': KitchenTicketStatus.queued.storageValue,
        'fired_at': timestamp,
        'updated_at': timestamp,
        'sync_state': 'pending',
      });

      final orderPayload = <String, Object?>{
        'schemaVersion': 1,
        'order': <String, Object?>{
          'id': draft.orderId,
          'organizationId': draft.organizationId,
          'branchId': draft.branchId,
          'deviceId': deviceId,
          'localOrderNumber': localOrderNumber,
          'status': 'saved',
          'orderType': draft.orderType.storageValue,
          'tableId': draft.tableId,
          'subtotalMinor': subtotal,
          'taxMinor': tax,
          'discountMinor': discount,
          'totalMinor': total,
          'currencyCode': draft.currencyCode,
          'note': _trimOrNull(draft.note),
          'openedBy': draft.openedBy,
          'createdAt': timestamp,
          'updatedAt': timestamp,
        },
        'lines': persistedLines,
        'kitchenTicketId': ticketId,
      };
      await _insertOutboxEvent(
        transaction,
        organizationId: draft.organizationId,
        branchId: draft.branchId,
        entityType: 'order',
        entityId: draft.orderId,
        operation: 'create',
        idempotencyKey: 'order:${draft.idempotencyKey}',
        payload: orderPayload,
        createdAt: timestamp,
      );
      await _insertOutboxEvent(
        transaction,
        organizationId: draft.organizationId,
        branchId: draft.branchId,
        entityType: 'kitchen_ticket',
        entityId: ticketId,
        operation: 'create',
        idempotencyKey: 'kitchen:${draft.idempotencyKey}',
        payload: <String, Object?>{
          'schemaVersion': 1,
          'id': ticketId,
          'organizationId': draft.organizationId,
          'branchId': draft.branchId,
          'orderId': draft.orderId,
          'status': KitchenTicketStatus.queued.storageValue,
          'firedAt': timestamp,
        },
        createdAt: timestamp,
      );

      return SaveOrderResult(
        orderId: draft.orderId,
        localOrderNumber: localOrderNumber,
        deviceId: deviceId,
        alreadySaved: false,
      );
    });
  }

  /// Applies the same logical Kitchen transition to its parent order atomically.
  Future<void> updateKitchenStatus({
    required String organizationId,
    required String branchId,
    required String orderId,
    required KitchenTicketStatus nextStatus,
    String? actorId,
  }) async {
    _validateUuid(organizationId, 'organizationId');
    _validateUuid(branchId, 'branchId');
    _validateUuid(orderId, 'orderId');
    if (actorId != null) {
      _validateUuid(actorId, 'actorId');
    }

    final database = await _database.open();
    await database.transaction((transaction) async {
      final rows = await transaction.query(
        'kitchen_tickets',
        where: 'order_id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, organizationId, branchId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('No kitchen ticket exists for this scoped order.');
      }
      final ticket = rows.single;
      final currentStatus = KitchenTicketStatus.values.firstWhere(
        (status) => status.storageValue == ticket['status'],
      );
      if (currentStatus == nextStatus) {
        return;
      }
      if (!_allowedKitchenTransitions[currentStatus]!.contains(nextStatus)) {
        throw StateError(
          'Invalid kitchen transition: ${currentStatus.storageValue} -> '
          '${nextStatus.storageValue}.',
        );
      }

      final orderRows = await transaction.query(
        'orders',
        columns: <String>['id'],
        where: 'id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, organizationId, branchId],
        limit: 1,
      );
      if (orderRows.isEmpty) {
        throw StateError('The scoped parent order does not exist.');
      }

      final timestamp = _timestamp();
      final ticketChanges = await transaction.update(
        'kitchen_tickets',
        <String, Object?>{
          'status': nextStatus.storageValue,
          'updated_at': timestamp,
          'sync_state': 'pending',
        },
        where: 'id = ? AND status = ?',
        whereArgs: <Object?>[ticket['id'], currentStatus.storageValue],
      );
      if (ticketChanges != 1) {
        throw StateError(
          'Kitchen ticket changed concurrently; reload the order.',
        );
      }

      final orderChanges = await transaction.update(
        'orders',
        <String, Object?>{
          'status': nextStatus.orderStatus,
          'updated_at': timestamp,
          'sync_state': 'pending',
        },
        where: 'id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, organizationId, branchId],
      );
      if (orderChanges != 1) {
        throw StateError(
          'Parent order changed concurrently; reload the order.',
        );
      }

      final eventId = _uuid.v4();
      await _insertOutboxEvent(
        transaction,
        organizationId: organizationId,
        branchId: branchId,
        entityType: 'kitchen_ticket',
        entityId: ticket['id']! as String,
        operation: 'transition',
        idempotencyKey: 'kitchen-transition:$eventId',
        payload: <String, Object?>{
          'schemaVersion': 1,
          'eventId': eventId,
          'orderId': orderId,
          'ticketId': ticket['id'],
          'actorId': actorId,
          'fromStatus': currentStatus.storageValue,
          'toStatus': nextStatus.storageValue,
          'orderStatus': nextStatus.orderStatus,
          'occurredAt': timestamp,
        },
        createdAt: timestamp,
      );
    });
  }

  Future<Map<String, Object?>?> readOrder({
    required String organizationId,
    required String branchId,
    required String orderId,
  }) async {
    final database = await _database.open();
    final rows = await database.query(
      'orders',
      where: 'id = ? AND organization_id = ? AND branch_id = ?',
      whereArgs: <Object?>[orderId, organizationId, branchId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }

    final order = Map<String, Object?>.from(rows.single);
    order['lines'] = await database.query(
      'order_lines',
      where: 'order_id = ?',
      whereArgs: <Object?>[orderId],
      orderBy: 'created_at ASC, id ASC',
    );
    final tickets = await database.query(
      'kitchen_tickets',
      where: 'order_id = ? AND organization_id = ? AND branch_id = ?',
      whereArgs: <Object?>[orderId, organizationId, branchId],
      limit: 1,
    );
    order['kitchenTicket'] = tickets.isEmpty ? null : tickets.single;
    return order;
  }

  Future<List<Map<String, Object?>>> listOrders({
    required String organizationId,
    required String branchId,
  }) async {
    final database = await _database.open();
    return database.query(
      'orders',
      where: 'organization_id = ? AND branch_id = ?',
      whereArgs: <Object?>[organizationId, branchId],
      orderBy: 'created_at DESC, local_order_number DESC',
    );
  }

  void _validateDraft(CreateOrderDraft draft) {
    _validateUuid(draft.orderId, 'orderId');
    _validateUuid(draft.idempotencyKey, 'idempotencyKey');
    _validateUuid(draft.organizationId, 'organizationId');
    _validateUuid(draft.branchId, 'branchId');
    if (draft.tableId != null) {
      _validateUuid(draft.tableId!, 'tableId');
    }
    if (draft.openedBy != null) {
      _validateUuid(draft.openedBy!, 'openedBy');
    }
    if (draft.lines.isEmpty) {
      throw ArgumentError('An order must contain at least one item.');
    }
    if (draft.lines.length > 1000) {
      throw ArgumentError('An order cannot contain more than 1000 lines.');
    }
    if (draft.orderType == MizzyOrderType.dineIn && draft.tableId == null) {
      throw ArgumentError('Dine-in orders must be assigned to a table.');
    }
    if (draft.currencyCode.length != 3 ||
        draft.currencyCode != draft.currencyCode.toUpperCase()) {
      throw ArgumentError.value(
        draft.currencyCode,
        'currencyCode',
        'must be a three-letter uppercase ISO currency code',
      );
    }
  }

  _ComputedLine _computeLine(OrderLineDraft line) {
    if (line.itemName.trim().isEmpty) {
      throw ArgumentError('Order item name must not be empty.');
    }
    if (line.catalogItemId != null) {
      _validateUuid(line.catalogItemId!, 'catalogItemId');
    }
    if (line.quantityMilli <= 0 || line.quantityMilli > 1000000000) {
      throw ArgumentError.value(
        line.quantityMilli,
        'quantityMilli',
        'must be between 1 and 1000000000',
      );
    }
    if (line.unitPriceMinor < 0 ||
        line.discountMinor < 0 ||
        line.taxMinor < 0) {
      throw ArgumentError('Price, discount, and tax must not be negative.');
    }

    final baseAmount =
        (BigInt.from(line.unitPriceMinor) * BigInt.from(line.quantityMilli) +
            BigInt.from(500)) ~/
        BigInt.from(1000);
    final subtotal = _checkedAmount(baseAmount, 'line subtotal');
    if (line.discountMinor > subtotal) {
      throw ArgumentError('Line discount cannot exceed the line subtotal.');
    }
    final lineTotal = _checkedAmount(
      baseAmount - BigInt.from(line.discountMinor) + BigInt.from(line.taxMinor),
      'line total',
    );
    return _ComputedLine(
      input: line,
      subtotalMinor: subtotal,
      discountMinor: line.discountMinor,
      taxMinor: line.taxMinor,
      lineTotalMinor: lineTotal,
    );
  }

  int _sumAmounts(Iterable<int> values, String label) {
    var result = BigInt.zero;
    for (final value in values) {
      result += BigInt.from(value);
    }
    return _checkedAmount(result, label);
  }

  int _checkedAmount(BigInt value, String label) {
    if (value < BigInt.zero || value > _maxSqlInteger) {
      throw ArgumentError('$label is outside the supported money range.');
    }
    return value.toInt();
  }

  String _fingerprint(CreateOrderDraft draft, List<_ComputedLine> lines) {
    final canonicalPayload = <String, Object?>{
      'orderId': draft.orderId,
      'organizationId': draft.organizationId,
      'branchId': draft.branchId,
      'orderType': draft.orderType.storageValue,
      'tableId': draft.tableId,
      'currencyCode': draft.currencyCode,
      'note': _trimOrNull(draft.note),
      'openedBy': draft.openedBy,
      'lines': lines
          .map(
            (line) => <String, Object?>{
              'catalogItemId': line.input.catalogItemId,
              'itemName': line.input.itemName.trim(),
              'sku': _trimOrNull(line.input.sku),
              'quantityMilli': line.input.quantityMilli,
              'unitPriceMinor': line.input.unitPriceMinor,
              'discountMinor': line.discountMinor,
              'taxMinor': line.taxMinor,
              'lineTotalMinor': line.lineTotalMinor,
            },
          )
          .toList(growable: false),
    };
    return sha256.convert(utf8.encode(jsonEncode(canonicalPayload))).toString();
  }

  Future<void> _insertOutboxEvent(
    Transaction transaction, {
    required String organizationId,
    required String branchId,
    required String entityType,
    required String entityId,
    required String operation,
    required String idempotencyKey,
    required Map<String, Object?> payload,
    required String createdAt,
  }) async {
    await transaction.insert('sync_outbox', <String, Object?>{
      'id': _uuid.v4(),
      'organization_id': organizationId,
      'branch_id': branchId,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'schema_version': 1,
      'payload_json': jsonEncode(payload),
      'idempotency_key': idempotencyKey,
      'status': 'pending',
      'attempts': 0,
      'created_at': createdAt,
    });
  }

  String _timestamp() => _clock().toUtc().toIso8601String();

  static String? _trimOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static void _validateUuid(String value, String field) {
    if (!Uuid.isValidUUIDFormat(fromString: value)) {
      throw ArgumentError.value(value, field, 'must be a UUID');
    }
  }
}

class _ComputedLine {
  const _ComputedLine({
    required this.input,
    required this.subtotalMinor,
    required this.discountMinor,
    required this.taxMinor,
    required this.lineTotalMinor,
  });

  final OrderLineDraft input;
  final int subtotalMinor;
  final int discountMinor;
  final int taxMinor;
  final int lineTotalMinor;
}
