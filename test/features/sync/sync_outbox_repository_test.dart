import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/sync/data/sync_outbox_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late MizzyDatabase database;
  late SyncOutboxRepository repository;
  late DateTime now;
  late String organizationId;
  late String branchId;

  setUp(() {
    now = DateTime.utc(2026, 10, 13, 12);
    organizationId = const Uuid().v4();
    branchId = const Uuid().v4();
    database = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: 'mizzy-outbox-test-${const Uuid().v4()}.db',
    );
    repository = SyncOutboxRepository(
      database: database,
      clock: () => now,
    );
  });

  tearDown(() async {
    await database.close();
  });

  Future<String> insertEvent({
    String? organization,
    String? branch,
    DateTime? createdAt,
    String? dependsOnEventId,
  }) async {
    final id = const Uuid().v4();
    final rawDatabase = await database.open();
    await rawDatabase.insert('sync_outbox', <String, Object?>{
      'id': id,
      'organization_id': organization ?? organizationId,
      'branch_id': branch ?? branchId,
      'entity_type': 'order',
      'entity_id': const Uuid().v4(),
      'operation': 'create',
      'schema_version': 1,
      'payload_json': '{"schemaVersion":1,"test":true}',
      'idempotency_key': const Uuid().v4(),
      'depends_on_event_id': dependsOnEventId,
      'status': 'pending',
      'attempts': 0,
      'created_at': (createdAt ?? now).toIso8601String(),
    });
    return id;
  }

  test(
    'claims only due events from the requested organization and branch',
    () async {
    final first = await insertEvent(
      createdAt: now.subtract(const Duration(seconds: 2)),
    );
    final second = await insertEvent(
      createdAt: now.subtract(const Duration(seconds: 1)),
    );
    final otherBranch = const Uuid().v4();
    final foreign = await insertEvent(branch: otherBranch);

    final claimed = await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
      limit: 10,
    );

    expect(claimed.map((event) => event.id), [first, second]);
    expect(claimed.map((event) => event.attempts), [1, 1]);
    expect(claimed.map((event) => event.status), ['processing', 'processing']);
    expect(
      claimed.every((event) => event.nextAttemptAt != null),
      isTrue,
    );

    final rawDatabase = await database.open();
    final foreignRow = (await rawDatabase.query(
      'sync_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[foreign],
      limit: 1,
    )).single;
    expect(foreignRow['status'], 'pending');
    expect(foreignRow['attempts'], 0);
    },
  );

  test(
    'dependent event waits for server-confirmed parent delivery',
    () async {
      final parentId = await insertEvent(
        createdAt: now.subtract(const Duration(seconds: 2)),
      );
      final childId = await insertEvent(
        dependsOnEventId: parentId,
        createdAt: now.subtract(const Duration(seconds: 1)),
      );

      final firstBatch = await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: 10,
      );
      expect(firstBatch.map((event) => event.id), [parentId]);
      expect(firstBatch.single.dependsOnEventId, isNull);

      await repository.markDelivered(
        organizationId: organizationId,
        branchId: branchId,
        eventId: parentId,
      );

      final secondBatch = await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: 10,
      );
      expect(secondBatch.map((event) => event.id), [childId]);
      expect(secondBatch.single.dependsOnEventId, parentId);
    },
  );

  test(
    'retry uses bounded exponential backoff and the safe error code',
    () async {
    final eventId = await insertEvent();
    final firstClaim = await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
    );
    expect(firstClaim.single.id, eventId);

    final retryAt = await repository.markRetryableFailure(
      organizationId: organizationId,
      branchId: branchId,
      eventId: eventId,
      failureCode: SyncFailureCode.networkUnavailable,
    );
    expect(retryAt, now.add(const Duration(seconds: 30)));

    var rawDatabase = await database.open();
    var row = (await rawDatabase.query(
      'sync_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[eventId],
      limit: 1,
    )).single;
    expect(row['status'], 'failed');
    expect(row['attempts'], 1);
    expect(row['last_error'], 'network_unavailable');

    now = retryAt.subtract(const Duration(seconds: 1));
    expect(
      await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
      ),
      isEmpty,
    );

    now = retryAt;
    final secondClaim = await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
    );
    expect(secondClaim.single.attempts, 2);
    final secondRetryAt = await repository.markRetryableFailure(
      organizationId: organizationId,
      branchId: branchId,
      eventId: eventId,
      failureCode: SyncFailureCode.timeout,
    );
    expect(secondRetryAt, now.add(const Duration(seconds: 60)));

    rawDatabase = await database.open();
    row = (await rawDatabase.query(
      'sync_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[eventId],
      limit: 1,
    )).single;
    expect(row['last_error'], 'timeout');
    expect(row['next_attempt_at'], secondRetryAt.toIso8601String());
    },
  );

  test(
    'expired processing lease can be safely reclaimed with a retry count',
    () async {
    final eventId = await insertEvent();
    final first = await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
      leaseDuration: const Duration(minutes: 2),
    );
    expect(first.single.attempts, 1);

    now = now.add(const Duration(minutes: 1, seconds: 59));
    expect(
      await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
      ),
      isEmpty,
    );

    now = now.add(const Duration(seconds: 1));
    final reclaimed = await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
    );
    expect(reclaimed.single.id, eventId);
    expect(reclaimed.single.attempts, 2);
    },
  );

  test('only a leased event can be marked delivered or quarantined', () async {
    final eventId = await insertEvent();
    await expectLater(
      repository.markDelivered(
        organizationId: organizationId,
        branchId: branchId,
        eventId: eventId,
      ),
      throwsStateError,
    );

    await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
    );
    await repository.markDelivered(
      organizationId: organizationId,
      branchId: branchId,
      eventId: eventId,
    );

    final rawDatabase = await database.open();
    var row = (await rawDatabase.query(
      'sync_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[eventId],
      limit: 1,
    )).single;
    expect(row['status'], 'done');
    expect(row['next_attempt_at'], isNull);
    expect(row['last_error'], isNull);

    final conflictId = await insertEvent();
    await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
    );
    await repository.markConflict(
      organizationId: organizationId,
      branchId: branchId,
      eventId: conflictId,
      failureCode: SyncFailureCode.rejectedByServer,
    );
    row = (await rawDatabase.query(
      'sync_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[conflictId],
      limit: 1,
    )).single;
    expect(row['status'], 'conflict');
    expect(row['last_error'], 'rejected_by_server');
    await expectLater(
      repository.markDelivered(
        organizationId: organizationId,
        branchId: branchId,
        eventId: conflictId,
      ),
      throwsStateError,
    );
  });

  test(
    'simultaneous claims lease each outbox event to only one worker',
    () async {
      final first = await insertEvent(
        createdAt: now.subtract(const Duration(seconds: 2)),
      );
      final second = await insertEvent(
        createdAt: now.subtract(const Duration(seconds: 1)),
      );

      final batches = await Future.wait([
        repository.claimNextBatch(
          organizationId: organizationId,
          branchId: branchId,
          limit: 1,
        ),
        repository.claimNextBatch(
          organizationId: organizationId,
          branchId: branchId,
          limit: 1,
        ),
      ]);

      final claimedIds = batches.expand((batch) => batch.map((event) => event.id));
      expect(claimedIds.toSet(), {first, second});
      expect(claimedIds.length, 2);

      final rawDatabase = await database.open();
      final rows = await rawDatabase.query(
        'sync_outbox',
        orderBy: 'created_at ASC',
      );
      expect(rows.map((row) => row['status']).toSet(), {'processing'});
      expect(rows.map((row) => row['attempts']).toSet(), {1});
    },
  );

  test('wrong-branch acknowledgment cannot mutate a leased event', () async {
    final eventId = await insertEvent();
    await repository.claimNextBatch(
      organizationId: organizationId,
      branchId: branchId,
    );

    await expectLater(
      repository.markDelivered(
        organizationId: organizationId,
        branchId: const Uuid().v4(),
        eventId: eventId,
      ),
      throwsStateError,
    );

    final rawDatabase = await database.open();
    final row = (await rawDatabase.query(
      'sync_outbox',
      where: 'id = ?',
      whereArgs: <Object?>[eventId],
      limit: 1,
    )).single;
    expect(row['status'], 'processing');
  });

  test('rejects invalid batch sizes and non-positive leases', () async {
    await expectLater(
      repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: 0,
      ),
      throwsA(isA<RangeError>()),
    );
    await expectLater(
      repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: SyncOutboxRepository.maximumBatchSize + 1,
      ),
      throwsA(isA<RangeError>()),
    );
    await expectLater(
      repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        leaseDuration: Duration.zero,
      ),
      throwsArgumentError,
    );
  });
}
