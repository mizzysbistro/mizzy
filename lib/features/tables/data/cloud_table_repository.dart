import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../../core/database/mizzy_database.dart';

typedef BranchTableAccessCheck = Future<bool> Function({
  required String organizationId,
  required String branchId,
});

abstract interface class CloudTableSource {
  Future<List<Map<String, Object?>>> fetchBranchTables({
    required String organizationId,
    required String branchId,
  });
}

class SupabaseCloudTableSource implements CloudTableSource {
  SupabaseCloudTableSource({required SupabaseClient client, this.pageSize = 200})
    : _client = client {
    if (pageSize < 1 || pageSize > 1000) {
      throw RangeError.range(pageSize, 1, 1000, 'pageSize');
    }
  }
  final SupabaseClient _client;
  final int pageSize;

  @override
  Future<List<Map<String, Object?>>> fetchBranchTables({
    required String organizationId,
    required String branchId,
  }) async {
    if (_client.auth.currentSession == null) {
      throw StateError('Sign in before refreshing restaurant tables.');
    }
    final all = <Map<String, Object?>>[];
    var offset = 0;
    while (true) {
      final page = await _client
          .from('restaurant_tables')
          .select('id,organization_id,branch_id,name,area_name,capacity,status,is_active,updated_at')
          .eq('organization_id', organizationId)
          .eq('branch_id', branchId)
          .order('id', ascending: true)
          .range(offset, offset + pageSize - 1);
      final rows = page.map((r) => Map<String, Object?>.from(r)).toList();
      all.addAll(rows);
      if (rows.length < pageSize) break;
      offset += pageSize;
    }
    return List<Map<String, Object?>>.unmodifiable(all);
  }
}

class CloudTableSyncResult {
  CloudTableSyncResult({
    required this.received,
    required this.inserted,
    required this.updated,
    required this.deactivated,
    required Iterable<String> conflictTableIds,
  }) : conflictTableIds = List<String>.unmodifiable(conflictTableIds);
  final int received;
  final int inserted;
  final int updated;
  final int deactivated;
  final List<String> conflictTableIds;
  int get conflicts => conflictTableIds.length;
}

/// Reads cloud tables into the local cache without blindly releasing local
/// reservations while an order is still queued for upload.
class CloudTableRepository {
  CloudTableRepository({
    required MizzyDatabase database,
    required CloudTableSource source,
    required BranchTableAccessCheck hasBranchAccess,
    DateTime Function()? clock,
  }) : _database = database,
       _source = source,
       _hasBranchAccess = hasBranchAccess,
       _clock = clock ?? DateTime.now;

  final MizzyDatabase _database;
  final CloudTableSource _source;
  final BranchTableAccessCheck _hasBranchAccess;
  final DateTime Function() _clock;

  Future<CloudTableSyncResult> syncBranch({
    required String organizationId,
    required String branchId,
  }) async {
    _uuid(organizationId, 'organizationId');
    _uuid(branchId, 'branchId');
    if (!await _hasBranchAccess(organizationId: organizationId, branchId: branchId)) {
      throw StateError('No active access to the selected restaurant branch.');
    }
    final rows = await _source.fetchBranchTables(
      organizationId: organizationId,
      branchId: branchId,
    );
    final tables = rows.map((r) => _CloudTable.parse(
      r, organizationId: organizationId, branchId: branchId,
    )).toList(growable: false);
    _validateUnique(tables);
    final ids = tables.map((t) => t.id).toSet();
    final nameOwners = <String, String>{for (final t in tables) t.name: t.id};
    final db = await _database.open();

    return db.transaction((tx) async {
      final now = _clock().toUtc().toIso8601String();
      var inserted = 0, updated = 0, deactivated = 0;
      final conflicts = <String>{};
      final cached = await tx.query(
        'restaurant_tables',
        where: 'organization_id = ? AND branch_id = ?',
        whereArgs: <Object?>[organizationId, branchId],
      );

      for (final row in cached) {
        final id = row['id']! as String;
        if (ids.contains(id)) continue;
        final oldName = row['name']! as String;
        final localState = row['sync_state']! as String;
        final changes = <String, Object?>{
          'status': 'inactive',
          'updated_at': now,
          'sync_state': localState == 'synced' ? 'synced' : 'conflict',
        };
        final newOwner = nameOwners[oldName];
        if (newOwner != null && newOwner != id) changes['name'] = _archived(oldName, id);
        if (localState != 'synced') conflicts.add(id);
        if (row['status'] != 'inactive') deactivated++;
        await tx.update(
          'restaurant_tables',
          changes,
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[id, organizationId, branchId],
        );
      }

      for (final table in tables) {
        final localRows = await tx.query(
          'restaurant_tables',
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[table.id, organizationId, branchId],
          limit: 1,
        );
        final local = localRows.isEmpty ? null : localRows.single;

        final collisions = await tx.query(
          'restaurant_tables',
          where: 'organization_id = ? AND branch_id = ? AND name = ? AND id <> ?',
          whereArgs: <Object?>[organizationId, branchId, table.name, table.id],
          limit: 1,
        );
        if (collisions.isNotEmpty) {
          final other = collisions.single;
          final otherId = other['id']! as String;
          final stillRemote = ids.contains(otherId);
          final rename = <String, Object?>{
            'name': _archived(table.name, otherId),
            'updated_at': now,
            'sync_state': other['sync_state'] == 'synced' ? 'synced' : 'conflict',
          };
          if (!stillRemote) rename['status'] = 'inactive';
          if (!stillRemote && other['status'] != 'inactive') deactivated++;
          if (other['sync_state'] != 'synced') conflicts.add(otherId);
          await tx.update(
            'restaurant_tables', rename,
            where: 'id = ? AND organization_id = ? AND branch_id = ?',
            whereArgs: <Object?>[otherId, organizationId, branchId],
          );
        }

        final remote = table.toRow();
        if (local == null) {
          await tx.insert('restaurant_tables', remote);
          inserted++;
          continue;
        }

        final localState = local['sync_state']! as String;
        final currentStatus = local['status']! as String;
        var status = table.localStatus;
        var syncState = 'synced';
        if (localState != 'synced') {
          if (!table.isActive || table.status == 'inactive') {
            status = 'inactive';
            syncState = 'conflict';
            conflicts.add(table.id);
          } else if (currentStatus == table.localStatus ||
              ((currentStatus == 'occupied' || currentStatus == 'reserved') &&
                  table.localStatus == 'available')) {
            // A matching row is not proof the queued local order was delivered.
            status = currentStatus;
            syncState = localState;
          } else if (currentStatus == 'available' &&
              (table.localStatus == 'occupied' || table.localStatus == 'reserved')) {
            status = table.localStatus;
            syncState = 'conflict';
            conflicts.add(table.id);
          } else {
            status = currentStatus;
            syncState = 'conflict';
            conflicts.add(table.id);
          }
        }

        final values = <String, Object?>{
          ...remote,
          'status': status,
          'sync_state': syncState,
          'updated_at': syncState == 'synced' ? table.updatedAt : now,
        };
        final changed = local['name'] != table.name ||
            local['area_name'] != table.areaName ||
            local['capacity'] != table.capacity ||
            currentStatus != status ||
            localState != syncState ||
            local['updated_at'] != values['updated_at'];
        await tx.update(
          'restaurant_tables',
          values,
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[table.id, organizationId, branchId],
        );
        if (changed) updated++;
        if (currentStatus != 'inactive' && status == 'inactive') deactivated++;
      }

      return CloudTableSyncResult(
        received: tables.length, inserted: inserted, updated: updated,
        deactivated: deactivated, conflictTableIds: conflicts,
      );
    });
  }

  static String _archived(String name, String id) {
    final suffix = ' [archived $id]';
    final length = 80 - suffix.length;
    return '${name.substring(0, name.length > length ? length : name.length)}$suffix';
  }

  static void _validateUnique(List<_CloudTable> tables) {
    final ids = <String>{}, names = <String>{};
    for (final table in tables) {
      if (!ids.add(table.id)) throw FormatException('Duplicate cloud table UUID: ${table.id}');
      if (!names.add(table.name)) throw FormatException('Duplicate cloud table name: ${table.name}');
    }
  }

  static void _uuid(String value, String field) {
    if (!Uuid.isValidUUIDFormat(fromString: value)) {
      throw ArgumentError.value(value, field, 'must be a UUID');
    }
  }
}

class _CloudTable {
  const _CloudTable({
    required this.id, required this.organizationId, required this.branchId,
    required this.name, required this.areaName, required this.capacity,
    required this.status, required this.isActive, required this.updatedAt,
  });
  final String id, organizationId, branchId, name, status, updatedAt;
  final String? areaName;
  final int capacity;
  final bool isActive;
  String get localStatus => isActive ? status : 'inactive';

  factory _CloudTable.parse(
    Map<String, Object?> row, {
    required String organizationId,
    required String branchId,
  }) {
    final id = _string(row, 'id'), org = _string(row, 'organization_id');
    final branch = _string(row, 'branch_id');
    if (!Uuid.isValidUUIDFormat(fromString: id) ||
        !Uuid.isValidUUIDFormat(fromString: org) ||
        !Uuid.isValidUUIDFormat(fromString: branch)) {
      throw const FormatException('Invalid cloud table UUID.');
    }
    if (org != organizationId || branch != branchId) {
      throw const FormatException('Cloud table is outside selected branch.');
    }
    final name = _string(row, 'name').trim();
    if (name.isEmpty || name.length > 80) throw const FormatException('Invalid table name.');
    final status = _string(row, 'status');
    if (!const {'available', 'occupied', 'reserved', 'inactive'}.contains(status)) {
      throw const FormatException('Invalid cloud table status.');
    }
    final active = row['is_active'];
    if (active is! bool) throw const FormatException('Invalid table activity flag.');
    final capacity = _integer(row['capacity'], 'capacity');
    if (capacity < 1 || capacity > 100) throw const FormatException('Invalid table capacity.');
    final parsed = DateTime.tryParse(_string(row, 'updated_at'));
    if (parsed == null) throw const FormatException('Invalid table timestamp.');
    return _CloudTable(
      id: id, organizationId: org, branchId: branch, name: name,
      areaName: _optional(row, 'area_name'), capacity: capacity, status: status,
      isActive: active, updatedAt: parsed.toUtc().toIso8601String(),
    );
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id, 'organization_id': organizationId, 'branch_id': branchId,
    'name': name, 'area_name': areaName, 'capacity': capacity,
    'status': localStatus, 'updated_at': updatedAt, 'sync_state': 'synced',
  };

  static String _string(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value is! String || value.trim().isEmpty) throw FormatException('Missing table field "$key".');
    return value;
  }
  static String? _optional(Map<String, Object?> row, String key) {
    final value = row[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('Invalid table field "$key".');
    return value.trim().isEmpty ? null : value.trim();
  }
  static int _integer(Object? value, String key) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.toInt()) return value.toInt();
    throw FormatException('Invalid integer table field "$key".');
  }
}
