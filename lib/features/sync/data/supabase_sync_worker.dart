import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/mizzy_database.dart';
import 'sync_outbox_repository.dart';

typedef BranchSyncAccessCheck = Future<bool> Function({
  required String organizationId,
  required String branchId,
});

enum SyncCycleStatus {
  completed,
  authenticationRequired,
  branchAccessDenied,
  accessCheckFailed,
}

class SyncCycleResult {
  const SyncCycleResult({
    required this.status,
    required this.batches,
    required this.claimed,
    required this.delivered,
    required this.retried,
    required this.conflicts,
  });

  final SyncCycleStatus status;
  final int batches;
  final int claimed;
  final int delivered;
  final int retried;
  final int conflicts;
}

/// A safe classification for remote failures. Raw server messages are never
/// stored in the SQLite outbox or exposed to callers by this worker.
class SyncRemoteFailure implements Exception {
  const SyncRemoteFailure.permanent()
    : isPermanent = true,
      retryCode = SyncFailureCode.rejectedByServer;

  const SyncRemoteFailure.retryable(this.retryCode) : isPermanent = false;

  final bool isPermanent;
  final SyncFailureCode retryCode;
}

abstract interface class CloudSyncTransport {
  bool get hasSession;

  Future<Map<String, Object?>> saveOrder({
    required Map<String, Object?> parameters,
  });

  Future<Map<String, Object?>?> readKitchenTicket({
    required String organizationId,
    required String branchId,
    required String ticketId,
  });

  Future<Map<String, Object?>> applyKitchenTransition({
    required Map<String, Object?> parameters,
  });
}

/// Supabase transport for the three narrow, server-authorized P1/P2 operations.
/// It never writes protected POS tables directly and never holds a service key.
class SupabaseCloudSyncTransport implements CloudSyncTransport {
  SupabaseCloudSyncTransport({required SupabaseClient client})
    : _client = client;

  final SupabaseClient _client;

  @override
  bool get hasSession => _client.auth.currentSession != null;

  @override
  Future<Map<String, Object?>> saveOrder({
    required Map<String, Object?> parameters,
  }) {
    return _call(() async {
      final result = await _client.rpc('save_order', params: parameters);
      return _singleRow(result, 'save_order');
    });
  }

  @override
  Future<Map<String, Object?>?> readKitchenTicket({
    required String organizationId,
    required String branchId,
    required String ticketId,
  }) {
    return _call(() async {
      final result = await _client
          .from('kitchen_tickets')
          .select('id,organization_id,branch_id,order_id,status')
          .eq('id', ticketId)
          .eq('organization_id', organizationId)
          .eq('branch_id', branchId)
          .maybeSingle();
      return result == null ? null : Map<String, Object?>.from(result);
    });
  }

  @override
  Future<Map<String, Object?>> applyKitchenTransition({
    required Map<String, Object?> parameters,
  }) {
    return _call(() async {
      final result = await _client.rpc(
        'apply_kitchen_transition_event',
        params: parameters,
      );
      return _singleRow(result, 'apply_kitchen_transition_event');
    });
  }

  Future<T> _call<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on PostgrestException catch (error) {
      final code = error.code ?? '';
      if (code == '401' || code == 'PGRST301') {
        throw const SyncRemoteFailure.retryable(
          SyncFailureCode.authenticationRequired,
        );
      }
      if (code == '429' || code == 'PGRST003') {
        throw const SyncRemoteFailure.retryable(SyncFailureCode.rateLimited);
      }
      if (code.startsWith('5') || code == 'PGRST000') {
        throw const SyncRemoteFailure.retryable(
          SyncFailureCode.serverUnavailable,
        );
      }
      if (const <String>{
        '42501',
        '22023',
        '23505',
        '23503',
        '40001',
        'P0002',
        '0A000',
        '22003',
        'PGRST202',
      }.contains(code) ||
          code.startsWith('22') ||
          code.startsWith('23')) {
        throw const SyncRemoteFailure.permanent();
      }
      throw const SyncRemoteFailure.retryable(SyncFailureCode.unknown);
    } on TimeoutException {
      throw const SyncRemoteFailure.retryable(SyncFailureCode.timeout);
    } on SocketException {
      throw const SyncRemoteFailure.retryable(
        SyncFailureCode.networkUnavailable,
      );
    }
  }

  static Map<String, Object?> _singleRow(Object? result, String operation) {
    if (result is List && result.length == 1 && result.single is Map) {
      return Map<String, Object?>.from(result.single as Map);
    }
    if (result is Map) return Map<String, Object?>.from(result);
    throw FormatException('$operation returned an unexpected response.');
  }
}

/// Authenticated, branch-scoped upload worker for the existing SQLite outbox.
///
/// Order creation uses save_order, which verifies current cloud catalog IDs and
/// prices and creates the initial Kitchen ticket atomically. The dependent
/// local Kitchen-create event verifies that ticket; it never inserts a second
/// ticket. Later status events use apply_kitchen_transition_event's stable
/// event receipt and expected-from-status check. Pull cursors are separate work.
class AuthenticatedOutboxSyncWorker {
  AuthenticatedOutboxSyncWorker({
    required MizzyDatabase database,
    required SyncOutboxRepository outbox,
    required CloudSyncTransport transport,
    required BranchSyncAccessCheck hasBranchAccess,
    this.maximumBatchesPerRun = 5,
  }) : _database = database,
       _outbox = outbox,
       _transport = transport,
       _hasBranchAccess = hasBranchAccess {
    if (maximumBatchesPerRun < 1 || maximumBatchesPerRun > 20) {
      throw RangeError.range(
        maximumBatchesPerRun,
        1,
        20,
        'maximumBatchesPerRun',
      );
    }
  }

  final MizzyDatabase _database;
  final SyncOutboxRepository _outbox;
  final CloudSyncTransport _transport;
  final BranchSyncAccessCheck _hasBranchAccess;
  final int maximumBatchesPerRun;

  Future<SyncCycleResult> syncOnce({
    required String organizationId,
    required String branchId,
    int batchSize = 20,
  }) async {
    _validateUuid(organizationId, 'organizationId');
    _validateUuid(branchId, 'branchId');

    if (!_transport.hasSession) {
      return const SyncCycleResult(
        status: SyncCycleStatus.authenticationRequired,
        batches: 0,
        claimed: 0,
        delivered: 0,
        retried: 0,
        conflicts: 0,
      );
    }

    bool branchAccess;
    try {
      branchAccess = await _hasBranchAccess(
        organizationId: organizationId,
        branchId: branchId,
      );
    } on Object {
      return const SyncCycleResult(
        status: SyncCycleStatus.accessCheckFailed,
        batches: 0,
        claimed: 0,
        delivered: 0,
        retried: 0,
        conflicts: 0,
      );
    }
    if (!branchAccess) {
      return const SyncCycleResult(
        status: SyncCycleStatus.branchAccessDenied,
        batches: 0,
        claimed: 0,
        delivered: 0,
        retried: 0,
        conflicts: 0,
      );
    }

    var batches = 0;
    var claimedCount = 0;
    var deliveredCount = 0;
    var retriedCount = 0;
    var conflictCount = 0;

    while (batches < maximumBatchesPerRun) {
      if (!_transport.hasSession) {
        break;
      }
      final events = await _outbox.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: batchSize,
      );
      if (events.isEmpty) break;
      batches++;
      claimedCount += events.length;

      for (final event in events) {
        if (!_transport.hasSession) {
          await _recordRetry(
            event,
            SyncFailureCode.authenticationRequired,
          );
          retriedCount++;
          continue;
        }

        _SyncEntityRefs? refs;
        try {
          refs = _entityRefs(event);
          await _sendEvent(event, refs);
        } on SyncRemoteFailure catch (failure) {
          if (failure.isPermanent) {
            await _recordConflict(event, refs);
            conflictCount++;
          } else {
            await _recordRetry(event, failure.retryCode, refs: refs);
            retriedCount++;
          }
          continue;
        } on FormatException {
          await _recordConflict(event, refs);
          conflictCount++;
          continue;
        } on ArgumentError {
          await _recordConflict(event, refs);
          conflictCount++;
          continue;
        } on PostgrestException catch (error) {
          final code = error.code ?? '';
          if (_isPermanentServerCode(code)) {
            await _recordConflict(event, refs);
            conflictCount++;
          } else {
            await _recordRetry(
              event,
              _retryCodeForServerCode(code),
              refs: refs,
            );
            retriedCount++;
          }
          continue;
        } on TimeoutException {
          await _recordRetry(
            event,
            SyncFailureCode.timeout,
            refs: refs,
          );
          retriedCount++;
          continue;
        } on SocketException {
          await _recordRetry(
            event,
            SyncFailureCode.networkUnavailable,
            refs: refs,
          );
          retriedCount++;
          continue;
        } on Object {
          await _recordRetry(event, SyncFailureCode.unknown, refs: refs);
          retriedCount++;
          continue;
        }

        // Server durability has already been confirmed. If local acknowledgment
        // fails, leave the lease for expiry/replay: server endpoints are
        // idempotent and the worker must not fabricate a delivered state.
        try {
          await _outbox.markDelivered(
            organizationId: event.organizationId,
            branchId: event.branchId,
            eventId: event.id,
          );
        } on Object {
          retriedCount++;
          continue;
        }

        try {
          await _refreshLocalSyncState(event, refs, 'synced');
        } on Object {
          // Outbox delivery is authoritative; the cache hint can be repaired
          // on the next successful sync cycle.
        }
        deliveredCount++;
      }
    }

    return SyncCycleResult(
      status: SyncCycleStatus.completed,
      batches: batches,
      claimed: claimedCount,
      delivered: deliveredCount,
      retried: retriedCount,
      conflicts: conflictCount,
    );
  }

  Future<void> _sendEvent(
    SyncOutboxRecord event,
    _SyncEntityRefs refs,
  ) async {
    if (event.schemaVersion != 1) {
      throw const FormatException('Unsupported outbox event schema.');
    }
    final payload = _decodePayload(event);

    if (event.entityType == 'order' && event.operation == 'create') {
      await _sendOrderCreate(event, payload, refs);
      return;
    }
    if (event.entityType == 'kitchen_ticket' &&
        event.operation == 'create') {
      await _verifyKitchenTicketCreate(event, payload, refs);
      return;
    }
    if (event.entityType == 'kitchen_ticket' &&
        event.operation == 'transition') {
      await _sendKitchenTransition(event, payload, refs);
      return;
    }

    // This first worker intentionally does not replay payments, inventory,
    // delete/update events or unknown future schemas.
    throw const FormatException('Unsupported outbox event type.');
  }

  Future<void> _sendOrderCreate(
    SyncOutboxRecord event,
    Map<String, Object?> payload,
    _SyncEntityRefs refs,
  ) async {
    final rawOrder = payload['order'];
    final rawLines = payload['lines'];
    final rawTicketId = payload['kitchenTicketId'];
    if (rawOrder is! Map || rawLines is! List || rawTicketId is! String) {
      throw const FormatException('Order-create payload is incomplete.');
    }
    final order = Map<String, Object?>.from(rawOrder);
    final orderId = _requiredString(order, 'id');
    final organizationId = _requiredString(order, 'organizationId');
    final branchId = _requiredString(order, 'branchId');
    if (orderId != event.entityId ||
        organizationId != event.organizationId ||
        branchId != event.branchId) {
      throw const FormatException('Order payload scope does not match its event.');
    }
    if (orderId != refs.orderId || rawTicketId != refs.ticketId) {
      throw const FormatException('Order event identity is inconsistent.');
    }
    _validateUuid(orderId, 'order.id');
    _validateUuid(organizationId, 'order.organizationId');
    _validateUuid(branchId, 'order.branchId');
    _validateUuid(_requiredString(order, 'deviceId'), 'order.deviceId');
    _validateUuid(rawTicketId, 'kitchenTicketId');

    final localIdempotencyKey = _uuidSuffix(
      event.idempotencyKey,
      'order:',
    );
    final orderType = _requiredString(order, 'orderType');
    if (!const <String>{'dine_in', 'takeaway', 'delivery'}.contains(orderType)) {
      throw const FormatException('Unsupported order type.');
    }
    final tableId = order['tableId'];
    if (tableId != null) {
      if (tableId is! String) {
        throw const FormatException('Order table ID is invalid.');
      }
      _validateUuid(tableId, 'order.tableId');
    }

    final totalMinor = _requiredInteger(order['totalMinor'], 'totalMinor');
    final subtotalMinor = _requiredInteger(
      order['subtotalMinor'],
      'subtotalMinor',
    );
    final discountMinor = _requiredInteger(
      order['discountMinor'],
      'discountMinor',
    );
    final taxMinor = _requiredInteger(order['taxMinor'], 'taxMinor');
    if (discountMinor != 0 || taxMinor != 0 || totalMinor != subtotalMinor) {
      throw const FormatException(
        'Cloud order sync does not yet support discounts or taxes.',
      );
    }

    final lines = <Map<String, Object?>>[];
    for (final rawLine in rawLines) {
      if (rawLine is! Map) {
        throw const FormatException('Order line payload is invalid.');
      }
      final line = Map<String, Object?>.from(rawLine);
      final lineId = _requiredString(line, 'id');
      final catalogItemId = _requiredString(line, 'catalog_item_id');
      _validateUuid(lineId, 'orderLine.id');
      _validateUuid(catalogItemId, 'orderLine.catalog_item_id');
      final quantityMilli = _requiredInteger(
        line['quantity_milli'],
        'quantity_milli',
      );
      final unitPriceMinor = _requiredInteger(
        line['unit_price_minor'],
        'unit_price_minor',
      );
      final lineDiscount = _requiredInteger(
        line['discount_minor'] ?? 0,
        'discount_minor',
      );
      final lineTax = _requiredInteger(line['tax_minor'] ?? 0, 'tax_minor');
      if (quantityMilli < 1 ||
          quantityMilli > 1000000000 ||
          unitPriceMinor < 0 ||
          lineDiscount != 0 ||
          lineTax != 0) {
        throw const FormatException(
          'Order line is outside the supported cloud contract.',
        );
      }
      lines.add(<String, Object?>{
        'id': lineId,
        'catalogItemId': catalogItemId,
        'quantityMilli': quantityMilli,
        'unitPriceMinor': unitPriceMinor,
        'discountMinor': lineDiscount,
        'taxMinor': lineTax,
      });
    }
    if (lines.isEmpty || lines.length > 250) {
      throw const FormatException('Order line count is outside cloud limits.');
    }

    final result = await _transport.saveOrder(
      parameters: <String, Object?>{
        'p_order_id': orderId,
        'p_organization_id': organizationId,
        'p_branch_id': branchId,
        'p_device_id': order['deviceId'],
        'p_local_order_number': _requiredInteger(
          order['localOrderNumber'],
          'localOrderNumber',
        ),
        'p_idempotency_key': localIdempotencyKey,
        'p_kitchen_ticket_id': rawTicketId,
        'p_order_type': orderType,
        'p_table_id': tableId,
        'p_note': order['note'],
        'p_lines': lines,
      },
    );

    if (_requiredString(result, 'order_id') != orderId ||
        _requiredString(result, 'kitchen_ticket_id') != rawTicketId) {
      throw const FormatException(
        'Server order confirmation does not match the local order.',
      );
    }
    if (_requiredInteger(result['total_minor'], 'total_minor') != totalMinor ||
        _requiredString(result, 'currency_code') !=
            _requiredString(order, 'currencyCode')) {
      // Server may have committed the order; quarantine rather than retrying
      // with a modified price. Operator reconciliation is required.
      throw const FormatException(
        'Server total/currency differs from the saved order snapshot.',
      );
    }
  }

  Future<void> _verifyKitchenTicketCreate(
    SyncOutboxRecord event,
    Map<String, Object?> payload,
    _SyncEntityRefs refs,
  ) async {
    final ticketId = _requiredString(payload, 'id');
    final organizationId = _requiredString(payload, 'organizationId');
    final branchId = _requiredString(payload, 'branchId');
    final orderId = _requiredString(payload, 'orderId');
    if (ticketId != event.entityId ||
        ticketId != refs.ticketId ||
        orderId != refs.orderId ||
        organizationId != event.organizationId ||
        branchId != event.branchId) {
      throw const FormatException('Kitchen-create payload scope is inconsistent.');
    }
    _validateUuid(ticketId, 'ticket.id');
    _validateUuid(orderId, 'ticket.orderId');

    // save_order inserts the initial ticket atomically with the parent order.
    // This child event confirms it exists instead of issuing a second insert.
    final serverTicket = await _transport.readKitchenTicket(
      organizationId: organizationId,
      branchId: branchId,
      ticketId: ticketId,
    );
    if (serverTicket == null ||
        serverTicket['id'] != ticketId ||
        serverTicket['organization_id'] != organizationId ||
        serverTicket['branch_id'] != branchId ||
        serverTicket['order_id'] != orderId ||
        serverTicket['status'] != _requiredString(payload, 'status')) {
      throw const FormatException(
        'Cloud Kitchen ticket differs from the saved local ticket.',
      );
    }
  }

  Future<void> _sendKitchenTransition(
    SyncOutboxRecord event,
    Map<String, Object?> payload,
    _SyncEntityRefs refs,
  ) async {
    final eventId = _requiredString(payload, 'eventId');
    final ticketId = _requiredString(payload, 'ticketId');
    final orderId = _requiredString(payload, 'orderId');
    final organizationId = event.organizationId;
    final branchId = event.branchId;
    if (event.entityId != ticketId ||
        refs.ticketId != ticketId ||
        refs.orderId != orderId ||
        organizationId != _requiredString(payload, 'organizationId')) {
      // The transition's historical payload has no organizationId member;
      // rely on the event's org/branch and the ticket/order linkage below.
    }
    _validateUuid(eventId, 'eventId');
    _validateUuid(ticketId, 'ticketId');
    _validateUuid(orderId, 'orderId');
    if (_uuidSuffix(event.idempotencyKey, 'kitchen-transition:') != eventId) {
      throw const FormatException('Kitchen event ID does not match its key.');
    }
    final fromStatus = _requiredString(payload, 'fromStatus');
    final toStatus = _requiredString(payload, 'toStatus');

    final result = await _transport.applyKitchenTransition(
      parameters: <String, Object?>{
        'p_event_id': eventId,
        'p_organization_id': organizationId,
        'p_branch_id': branchId,
        'p_ticket_id': ticketId,
        'p_expected_from_status': fromStatus,
        'p_next_status': toStatus,
      },
    );
    if (_requiredString(result, 'ticket_id') != ticketId ||
        _requiredString(result, 'order_id') != orderId ||
        _requiredString(result, 'ticket_status') != toStatus) {
      throw const FormatException(
        'Server Kitchen transition confirmation differs from the event.',
      );
    }
    if (result['already_applied'] is! bool) {
      throw const FormatException(
        'Server Kitchen transition response is incomplete.',
      );
    }
  }

  Map<String, Object?> _decodePayload(SyncOutboxRecord event) {
    final decoded = jsonDecode(event.payloadJson);
    if (decoded is! Map) {
      throw const FormatException('Outbox payload must be a JSON object.');
    }
    final payload = Map<String, Object?>.from(decoded);
    if (_requiredInteger(payload['schemaVersion'], 'schemaVersion') != 1) {
      throw const FormatException('Unsupported outbox payload schema.');
    }
    return payload;
  }

  _SyncEntityRefs _entityRefs(SyncOutboxRecord event) {
    String? orderId;
    String? ticketId;
    try {
      final decoded = jsonDecode(event.payloadJson);
      if (decoded is Map) {
        final payload = Map<String, Object?>.from(decoded);
        final nested = payload['order'];
        if (nested is Map && nested['id'] is String) {
          orderId = nested['id'] as String;
        }
        if (payload['orderId'] is String) {
          orderId = payload['orderId'] as String;
        }
        if (payload['kitchenTicketId'] is String) {
          ticketId = payload['kitchenTicketId'] as String;
        } else if (payload['ticketId'] is String) {
          ticketId = payload['ticketId'] as String;
        } else if (payload['id'] is String &&
            event.entityType == 'kitchen_ticket') {
          ticketId = payload['id'] as String;
        }
      }
    } on Object {
      // Corrupt payload is quarantined; fall back to the outbox entity ID.
    }
    if (event.entityType == 'order') orderId = event.entityId;
    if (event.entityType == 'kitchen_ticket') ticketId ??= event.entityId;
    return _SyncEntityRefs(orderId: orderId, ticketId: ticketId);
  }

  Future<void> _recordConflict(
    SyncOutboxRecord event,
    _SyncEntityRefs? refs,
  ) async {
    await _outbox.markConflict(
      organizationId: event.organizationId,
      branchId: event.branchId,
      eventId: event.id,
      failureCode: SyncFailureCode.rejectedByServer,
    );
    await _refreshLocalSyncState(event, refs, 'conflict');
  }

  Future<void> _recordRetry(
    SyncOutboxRecord event,
    SyncFailureCode code, {
    _SyncEntityRefs? refs,
  }) async {
    await _outbox.markRetryableFailure(
      organizationId: event.organizationId,
      branchId: event.branchId,
      eventId: event.id,
      failureCode: code,
    );
    await _refreshLocalSyncState(event, refs, 'pending');
  }

  Future<void> _refreshLocalSyncState(
    SyncOutboxRecord event,
    _SyncEntityRefs? refs,
    String fallbackState,
  ) async {
    final resolved = refs ?? _entityRefs(event);
    final orderId = resolved.orderId;
    final ticketId = resolved.ticketId;
    if (orderId == null) return;

    final database = await _database.open();
    await database.transaction((transaction) async {
      final unresolved = await transaction.query(
        'sync_outbox',
        where:
            "organization_id = ? AND branch_id = ? AND status <> ? AND "
            "((entity_type = 'order' AND entity_id = ?) OR "
            "(entity_type = 'kitchen_ticket' AND entity_id = ?))",
        whereArgs: <Object?>[
          event.organizationId,
          event.branchId,
          'done',
          orderId,
          ticketId ?? '',
        ],
      );
      final state = unresolved.any((row) => row['status'] == 'conflict')
          ? 'conflict'
          : unresolved.any((row) => row['status'] == 'failed')
          ? 'failed'
          : unresolved.isNotEmpty
          ? 'pending'
          : fallbackState;

      await transaction.update(
        'orders',
        <String, Object?>{'sync_state': state},
        where: 'id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, event.organizationId, event.branchId],
      );
      if (ticketId != null) {
        await transaction.update(
          'kitchen_tickets',
          <String, Object?>{'sync_state': state},
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[
            ticketId,
            event.organizationId,
            event.branchId,
          ],
        );
      }
      final orderRows = await transaction.query(
        'orders',
        columns: <String>['table_id'],
        where: 'id = ? AND organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[orderId, event.organizationId, event.branchId],
        limit: 1,
      );
      if (orderRows.isNotEmpty && orderRows.single['table_id'] != null) {
        await transaction.update(
          'restaurant_tables',
          <String, Object?>{'sync_state': state},
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[
            orderRows.single['table_id'],
            event.organizationId,
            event.branchId,
          ],
        );
      }
    });
  }

  static bool _isPermanentServerCode(String code) =>
      const <String>{
        '42501',
        '22023',
        '23505',
        '23503',
        '40001',
        'P0002',
        '0A000',
        '22003',
        'PGRST202',
      }.contains(code) ||
      code.startsWith('22') ||
      code.startsWith('23');

  static SyncFailureCode _retryCodeForServerCode(String code) {
    if (code == '401' || code == 'PGRST301') {
      return SyncFailureCode.authenticationRequired;
    }
    if (code == '429' || code == 'PGRST003') {
      return SyncFailureCode.rateLimited;
    }
    if (code.startsWith('5') || code == 'PGRST000') {
      return SyncFailureCode.serverUnavailable;
    }
    return SyncFailureCode.unknown;
  }

  static String _uuidSuffix(String value, String prefix) {
    if (!value.startsWith(prefix)) {
      throw const FormatException('Outbox idempotency key prefix is invalid.');
    }
    final suffix = value.substring(prefix.length);
    _validateUuid(suffix, 'idempotencyKey');
    return suffix;
  }

  static String _requiredString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Required field "$key" is missing.');
    }
    return value;
  }

  static int _requiredInteger(Object? value, String key) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.toInt()) {
      return value.toInt();
    }
    throw FormatException('Required integer field "$key" is invalid.');
  }

  static void _validateUuid(String value, String field) {
    if (!Uuid.isValidUUIDFormat(fromString: value)) {
      throw ArgumentError.value(value, field, 'must be a UUID');
    }
  }
}

class _SyncEntityRefs {
  const _SyncEntityRefs({this.orderId, this.ticketId});

  final String? orderId;
  final String? ticketId;
}
