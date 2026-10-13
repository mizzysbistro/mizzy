import 'package:uuid/uuid.dart';

import '../../../core/database/mizzy_database.dart';

enum SyncFailureCode {
  networkUnavailable('network_unavailable'),
  authenticationRequired('authentication_required'),
  timeout('timeout'),
  serverUnavailable('server_unavailable'),
  rateLimited('rate_limited'),
  rejectedByServer('rejected_by_server'),
  unknown('unknown');

  const SyncFailureCode(this.storageValue);

  final String storageValue;
}

class SyncOutboxRecord {
  const SyncOutboxRecord({
    required this.id,
    required this.organizationId,
    required this.branchId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.schemaVersion,
    required this.payloadJson,
    required this.idempotencyKey,
    required this.status,
    required this.attempts,
    required this.createdAt,
    this.nextAttemptAt,
    this.dependsOnEventId,
  });

  factory SyncOutboxRecord.fromRow(Map<String, Object?> row) {
    return SyncOutboxRecord(
      id: row['id']! as String,
      organizationId: row['organization_id']! as String,
      branchId: row['branch_id']! as String,
      entityType: row['entity_type']! as String,
      entityId: row['entity_id']! as String,
      operation: row['operation']! as String,
      schemaVersion: row['schema_version']! as int,
      payloadJson: row['payload_json']! as String,
      idempotencyKey: row['idempotency_key']! as String,
      status: row['status']! as String,
      attempts: row['attempts']! as int,
      createdAt: row['created_at']! as String,
      nextAttemptAt: row['next_attempt_at'] as String?,
      dependsOnEventId: row['depends_on_event_id'] as String?,
    );
  }

  final String id;
  final String organizationId;
  final String branchId;
  final String entityType;
  final String entityId;
  final String operation;
  final int schemaVersion;
  final String payloadJson;
  final String idempotencyKey;
  final String status;
  final int attempts;
  final String createdAt;
  final String? nextAttemptAt;
  final String? dependsOnEventId;
}

/// Manages durable local outbox transitions. Network operations live in
/// the authenticated sync worker; an event may be marked delivered only after
/// its idempotent server operation or verification succeeds.
class SyncOutboxRepository {
  SyncOutboxRepository({
    required MizzyDatabase database,
    DateTime Function()? clock,
  }) : _database = database,
       _clock = clock ?? DateTime.now;

  final MizzyDatabase _database;
  final DateTime Function() _clock;

  static const Duration defaultLeaseDuration = Duration(minutes: 5);
  static const int maximumBatchSize = 100;
  static const int _initialBackoffSeconds = 30;
  static const int _maximumBackoffSeconds = 3600;

  /// Atomically leases due events for exactly one organization/branch.
  ///
  /// Processing events whose lease has expired are reclaimable. The server
  /// must still enforce idempotency because a slow request may outlive a lease.
  Future<List<SyncOutboxRecord>> claimNextBatch({
    required String organizationId,
    required String branchId,
    int limit = 20,
    Duration leaseDuration = defaultLeaseDuration,
  }) async {
    _validateUuid(organizationId, 'organizationId');
    _validateUuid(branchId, 'branchId');
    if (limit < 1 || limit > maximumBatchSize) {
      throw RangeError.range(limit, 1, maximumBatchSize, 'limit');
    }
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'must be positive',
      );
    }

    final database = await _database.open();
    return database.transaction((transaction) async {
      final now = _timestamp();
      final leaseExpiry = _clock().toUtc().add(leaseDuration).toIso8601String();
      final candidates = await transaction.query(
        'sync_outbox',
        where: '''
          organization_id = ? AND branch_id = ? AND (
            (status IN ('pending', 'failed')
              AND (next_attempt_at IS NULL OR next_attempt_at <= ?))
            OR (status = 'processing' AND next_attempt_at <= ?)
          )
          AND (
            depends_on_event_id IS NULL OR EXISTS (
              SELECT 1
              FROM sync_outbox AS dependency
              WHERE dependency.id = sync_outbox.depends_on_event_id
                AND dependency.organization_id = sync_outbox.organization_id
                AND dependency.branch_id = sync_outbox.branch_id
                AND dependency.status = 'done'
            )
          )
        ''',
        whereArgs: <Object?>[
          organizationId,
          branchId,
          now,
          now,
        ],
        orderBy: 'created_at ASC, id ASC',
        limit: limit,
      );

      final claimed = <SyncOutboxRecord>[];
      for (final candidate in candidates) {
        final status = candidate['status']! as String;
        final id = candidate['id']! as String;
        final changed = await transaction.update(
          'sync_outbox',
          <String, Object?>{
            'status': 'processing',
            'attempts': (candidate['attempts']! as int) + 1,
            'next_attempt_at': leaseExpiry,
            'last_error': null,
          },
          where:
              'id = ? AND organization_id = ? AND branch_id = ? AND status = ?',
          whereArgs: <Object?>[id, organizationId, branchId, status],
        );
        if (changed != 1) continue;

        claimed.add(
          SyncOutboxRecord.fromRow(<String, Object?>{
            ...candidate,
            'status': 'processing',
            'attempts': (candidate['attempts']! as int) + 1,
            'next_attempt_at': leaseExpiry,
            'last_error': null,
          }),
        );
      }
      return claimed;
    });
  }

  Future<void> markDelivered({
    required String organizationId,
    required String branchId,
    required String eventId,
  }) async {
    _validateScope(organizationId, branchId, eventId);
    final database = await _database.open();
    final changed = await database.update(
      'sync_outbox',
      <String, Object?>{
        'status': 'done',
        'next_attempt_at': null,
        'last_error': null,
      },
      where:
          'id = ? AND organization_id = ? AND branch_id = ? AND status = ?',
      whereArgs: <Object?>[
        eventId,
        organizationId,
        branchId,
        'processing',
      ],
    );
    if (changed != 1) {
      throw StateError('Only a leased event in this branch can be delivered.');
    }
  }

  /// Stores a bounded, non-sensitive failure code and schedules exponential
  /// backoff. Raw server messages, tokens and customer data are never logged.
  Future<DateTime> markRetryableFailure({
    required String organizationId,
    required String branchId,
    required String eventId,
    required SyncFailureCode failureCode,
  }) async {
    _validateScope(organizationId, branchId, eventId);
    final database = await _database.open();
    return database.transaction((transaction) async {
      final rows = await transaction.query(
        'sync_outbox',
        columns: <String>['attempts'],
        where:
            'id = ? AND organization_id = ? AND branch_id = ? AND status = ?',
        whereArgs: <Object?>[
          eventId,
          organizationId,
          branchId,
          'processing',
        ],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw StateError('Only a leased event in this branch can be retried.');
      }

      final attempts = rows.single['attempts']! as int;
      final exponent = attempts > 8 ? 7 : attempts - 1;
      final delaySeconds = (_initialBackoffSeconds * (1 << exponent))
          .clamp(_initialBackoffSeconds, _maximumBackoffSeconds)
          .toInt();
      final retryAt = _clock().toUtc().add(Duration(seconds: delaySeconds));
      final changed = await transaction.update(
        'sync_outbox',
        <String, Object?>{
          'status': 'failed',
          'next_attempt_at': retryAt.toIso8601String(),
          'last_error': failureCode.storageValue,
        },
        where:
            'id = ? AND organization_id = ? AND branch_id = ? AND status = ?',
        whereArgs: <Object?>[
          eventId,
          organizationId,
          branchId,
          'processing',
        ],
      );
      if (changed != 1) {
        throw StateError('Outbox event changed while recording retry.');
      }
      return retryAt;
    });
  }

  /// Quarantines an event when the server reports a permanent conflict.
  Future<void> markConflict({
    required String organizationId,
    required String branchId,
    required String eventId,
    required SyncFailureCode failureCode,
  }) async {
    _validateScope(organizationId, branchId, eventId);
    final database = await _database.open();
    final changed = await database.update(
      'sync_outbox',
      <String, Object?>{
        'status': 'conflict',
        'next_attempt_at': null,
        'last_error': failureCode.storageValue,
      },
      where:
          'id = ? AND organization_id = ? AND branch_id = ? AND status = ?',
      whereArgs: <Object?>[
        eventId,
        organizationId,
        branchId,
        'processing',
      ],
    );
    if (changed != 1) {
      throw StateError(
        'Only a leased event in this branch can be quarantined.',
      );
    }
  }

  String _timestamp() => _clock().toUtc().toIso8601String();

  static void _validateScope(
    String organizationId,
    String branchId,
    String eventId,
  ) {
    _validateUuid(organizationId, 'organizationId');
    _validateUuid(branchId, 'branchId');
    _validateUuid(eventId, 'eventId');
  }

  static void _validateUuid(String value, String field) {
    if (!Uuid.isValidUUIDFormat(fromString: value)) {
      throw ArgumentError.value(value, field, 'must be a UUID');
    }
  }
}
