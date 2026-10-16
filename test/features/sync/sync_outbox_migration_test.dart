import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/sync/data/sync_outbox_repository.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  test('v1 migration chains old Kitchen events and quarantines orphans', () async {
    final databaseName = 'mizzy-migration-${const Uuid().v4()}.db';
    final databaseDirectory = await databaseFactoryFfi.getDatabasesPath();
    final databasePath = p.join(databaseDirectory, databaseName);
    final organizationId = const Uuid().v4();
    final branchId = const Uuid().v4();
    final orderId = const Uuid().v4();
    final ticketId = const Uuid().v4();
    final orderEventId = const Uuid().v4();
    final ticketEventId = const Uuid().v4();
    final transitionEventId = const Uuid().v4();
    final orphanEventId = const Uuid().v4();
    final clock = DateTime.utc(2026, 10, 14, 12);

    final versionOne = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (database, _) async {
          await database.execute('''
            CREATE TABLE local_meta (
              meta_key TEXT PRIMARY KEY NOT NULL,
              meta_value TEXT NOT NULL
            )
          ''');
          await database.execute('''
            CREATE TABLE sync_outbox (
              id TEXT PRIMARY KEY NOT NULL,
              organization_id TEXT NOT NULL,
              branch_id TEXT NOT NULL,
              entity_type TEXT NOT NULL,
              entity_id TEXT NOT NULL,
              operation TEXT NOT NULL,
              schema_version INTEGER NOT NULL DEFAULT 1,
              payload_json TEXT NOT NULL,
              idempotency_key TEXT NOT NULL UNIQUE,
              status TEXT NOT NULL DEFAULT 'pending',
              attempts INTEGER NOT NULL DEFAULT 0,
              next_attempt_at TEXT,
              last_error TEXT,
              created_at TEXT NOT NULL
            )
          ''');
          await database.insert('local_meta', <String, Object?>{
            'meta_key': 'schema_version',
            'meta_value': '1',
          });
        },
      ),
    );

    Future<void> insertLegacyEvent({
      required String id,
      required String entityType,
      required String entityId,
      required String operation,
      required Map<String, Object?> payload,
    }) async {
      await versionOne.insert('sync_outbox', <String, Object?>{
        'id': id,
        'organization_id': organizationId,
        'branch_id': branchId,
        'entity_type': entityType,
        'entity_id': entityId,
        'operation': operation,
        'schema_version': 1,
        'payload_json': jsonEncode(payload),
        'idempotency_key': const Uuid().v4(),
        'status': 'pending',
        'attempts': 0,
        'created_at': clock.toIso8601String(),
      });
    }

    await insertLegacyEvent(
      id: orderEventId,
      entityType: 'order',
      entityId: orderId,
      operation: 'create',
      payload: <String, Object?>{
        'schemaVersion': 1,
        'order': <String, Object?>{'id': orderId},
        'lines': <Object?>[],
        'kitchenTicketId': ticketId,
      },
    );
    await insertLegacyEvent(
      id: ticketEventId,
      entityType: 'kitchen_ticket',
      entityId: ticketId,
      operation: 'create',
      payload: <String, Object?>{
        'schemaVersion': 1,
        'id': ticketId,
        'orderId': orderId,
      },
    );
    await insertLegacyEvent(
      id: transitionEventId,
      entityType: 'kitchen_ticket',
      entityId: ticketId,
      operation: 'transition',
      payload: <String, Object?>{
        'schemaVersion': 1,
        'orderId': orderId,
        'ticketId': ticketId,
      },
    );
    await insertLegacyEvent(
      id: orphanEventId,
      entityType: 'kitchen_ticket',
      entityId: const Uuid().v4(),
      operation: 'create',
      payload: <String, Object?>{
        'schemaVersion': 1,
        'orderId': const Uuid().v4(),
      },
    );
    await versionOne.close();

    final upgradedDatabase = MizzyDatabase(
      factory: databaseFactoryFfi,
      databaseName: databaseName,
    );
    try {
      final database = await upgradedDatabase.open();
      final columns = await database.rawQuery('PRAGMA table_info(sync_outbox)');
      expect(
        columns.any((column) => column['name'] == 'depends_on_event_id'),
        isTrue,
      );

      final events = await database.query('sync_outbox');
      final byId = <String, Map<String, Object?>>{
        for (final event in events) event['id']! as String: event,
      };
      expect(byId[ticketEventId]!['depends_on_event_id'], orderEventId);
      expect(byId[transitionEventId]!['depends_on_event_id'], ticketEventId);
      expect(byId[orphanEventId]!['status'], 'conflict');
      expect(
        byId[orphanEventId]!['last_error'],
        'dependency_backfill_unresolved',
      );

      final repository = SyncOutboxRepository(
        database: upgradedDatabase,
        clock: () => clock,
      );
      final firstBatch = await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: 10,
      );
      expect(firstBatch.map((event) => event.id), [orderEventId]);

      await repository.markDelivered(
        organizationId: organizationId,
        branchId: branchId,
        eventId: orderEventId,
      );
      final secondBatch = await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: 10,
      );
      expect(secondBatch.map((event) => event.id), [ticketEventId]);

      await repository.markDelivered(
        organizationId: organizationId,
        branchId: branchId,
        eventId: ticketEventId,
      );
      final thirdBatch = await repository.claimNextBatch(
        organizationId: organizationId,
        branchId: branchId,
        limit: 10,
      );
      expect(thirdBatch.map((event) => event.id), [transitionEventId]);
    } finally {
      await upgradedDatabase.close();
      await databaseFactoryFfi.deleteDatabase(databasePath);
    }
  });
}
