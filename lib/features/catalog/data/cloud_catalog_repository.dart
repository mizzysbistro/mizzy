import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/mizzy_database.dart';

typedef BranchCatalogAccessCheck = Future<bool> Function({
  required String organizationId,
  required String branchId,
});

/// Reads the cloud menu using the caller's Supabase Auth session and RLS.
/// Fetch inactive rows too, so deactivated items are not kept active offline.
abstract interface class CloudCatalogSource {
  Future<List<Map<String, Object?>>> fetchBranchItems({
    required String organizationId,
    required String branchId,
  });
}

class SupabaseCloudCatalogSource implements CloudCatalogSource {
  SupabaseCloudCatalogSource({
    required SupabaseClient client,
    this.pageSize = 200,
  }) : _client = client {
    if (pageSize < 1 || pageSize > 1000) {
      throw RangeError.range(pageSize, 1, 1000, 'pageSize');
    }
  }

  final SupabaseClient _client;
  final int pageSize;

  static const String _selectColumns =
      'id,organization_id,branch_id,name,sku,category_name,price_minor,'
      'currency_code,is_active,updated_at';

  @override
  Future<List<Map<String, Object?>>> fetchBranchItems({
    required String organizationId,
    required String branchId,
  }) async {
    if (_client.auth.currentSession == null) {
      throw StateError('Sign in before refreshing the cloud menu.');
    }

    final items = <Map<String, Object?>>[];
    var offset = 0;
    while (true) {
      final page = await _client
          .from('menu_items')
          .select(_selectColumns)
          .eq('organization_id', organizationId)
          .eq('branch_id', branchId)
          .order('id', ascending: true)
          .range(offset, offset + pageSize - 1);

      final rows = page
          .map((row) => Map<String, Object?>.from(row))
          .toList(growable: false);
      items.addAll(rows);
      if (rows.length < pageSize) break;
      offset += pageSize;
    }

    return List<Map<String, Object?>>.unmodifiable(items);
  }
}

class CloudCatalogSyncResult {
  CloudCatalogSyncResult({
    required this.received,
    required this.inserted,
    required this.updated,
    required this.deactivated,
    required Iterable<String> conflictItemIds,
  }) : conflictItemIds = List<String>.unmodifiable(conflictItemIds);

  final int received;
  final int inserted;
  final int updated;
  final int deactivated;
  final List<String> conflictItemIds;

  int get conflicts => conflictItemIds.length;
}

/// Reconciles a full authenticated cloud catalog pull into SQLite.
///
/// This is a local cache primitive, not a catalog-management API. Its caller
/// must provide a membership check using the current AuthRepository's branch
/// access results. Supabase RLS remains the server-side authorization boundary.
class CloudCatalogRepository {
  CloudCatalogRepository({
    required MizzyDatabase database,
    required CloudCatalogSource source,
    required BranchCatalogAccessCheck hasBranchAccess,
    DateTime Function()? clock,
  }) : _database = database,
       _source = source,
       _hasBranchAccess = hasBranchAccess,
       _clock = clock ?? DateTime.now;

  final MizzyDatabase _database;
  final CloudCatalogSource _source;
  final BranchCatalogAccessCheck _hasBranchAccess;
  final DateTime Function() _clock;

  Future<CloudCatalogSyncResult> syncBranch({
    required String organizationId,
    required String branchId,
  }) async {
    _validateUuid(organizationId, 'organizationId');
    _validateUuid(branchId, 'branchId');

    if (!await _hasBranchAccess(
      organizationId: organizationId,
      branchId: branchId,
    )) {
      throw StateError('No active access to the selected restaurant branch.');
    }

    // Complete fetch and validate before opening a write transaction. Network
    // errors or malformed/foreign rows cannot leave a partially updated cache.
    final remoteRows = await _source.fetchBranchItems(
      organizationId: organizationId,
      branchId: branchId,
    );
    final remoteItems = remoteRows
        .map(
          (row) => _CloudCatalogItem.fromRow(
            row,
            organizationId: organizationId,
            branchId: branchId,
          ),
        )
        .toList(growable: false);
    _validateUniqueRemoteItems(remoteItems);

    final remoteIds = remoteItems.map((item) => item.id).toSet();
    final remoteSkuOwners = <String, String>{
      for (final item in remoteItems)
        if (item.sku != null) item.sku!: item.id,
    };

    final database = await _database.open();
    return database.transaction((transaction) async {
      var inserted = 0;
      var updated = 0;
      var deactivated = 0;
      final conflicts = <String>{};
      final now = _timestamp();

      // Preserve local order history, but make cloud-deleted items unavailable.
      // If a SKU is reused for a new cloud UUID, release the obsolete cached
      // SKU without deleting its row or rewriting sale-line snapshots.
      final cachedSyncedItems = await transaction.query(
        'catalog_items',
        where:
            'organization_id = ? AND branch_id = ? AND sync_state = ?',
        whereArgs: <Object?>[organizationId, branchId, 'synced'],
      );
      for (final cached in cachedSyncedItems) {
        final cachedId = cached['id']! as String;
        if (remoteIds.contains(cachedId)) continue;

        final oldSku = cached['sku'] as String?;
        final skuReused = oldSku != null &&
            remoteSkuOwners.containsKey(oldSku) &&
            remoteSkuOwners[oldSku] != cachedId;
        final changes = <String, Object?>{
          'is_active': 0,
          'updated_at': now,
          'sync_state': 'synced',
        };
        if (skuReused) changes['sku'] = null;

        await transaction.update(
          'catalog_items',
          changes,
          where:
              'id = ? AND organization_id = ? AND branch_id = ? '
              'AND sync_state = ?',
          whereArgs: <Object?>[
            cachedId,
            organizationId,
            branchId,
            'synced',
          ],
        );
        if ((cached['is_active']! as int) != 0) deactivated++;
      }

      // The current app does not yet upload catalog mutations. A local-only
      // item under a cloud branch therefore cannot be treated as sellable or
      // guaranteed to sync with its orders. Quarantine it until it is explicitly
      // reconciled with a server-owned catalog UUID.
      final unsyncedCachedItems = await transaction.query(
        'catalog_items',
        where:
            'organization_id = ? AND branch_id = ? '
            'AND sync_state IN (?, ?, ?)',
        whereArgs: <Object?>[
          organizationId,
          branchId,
          'local',
          'pending',
          'failed',
        ],
      );
      for (final cached in unsyncedCachedItems) {
        final cachedId = cached['id']! as String;
        if (remoteIds.contains(cachedId)) continue;
        await transaction.update(
          'catalog_items',
          <String, Object?>{
            'is_active': 0,
            'sync_state': 'conflict',
            'updated_at': now,
          },
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[cachedId, organizationId, branchId],
        );
        conflicts.add(cachedId);
      }

      for (final item in remoteItems) {
        final existingRows = await transaction.query(
          'catalog_items',
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[item.id, organizationId, branchId],
          limit: 1,
        );
        final existing = existingRows.isEmpty ? null : existingRows.single;

        // Different local UUID + same SKU is a conflict, not permission to
        // silently replace item identity or re-price any saved order.
        final skuCollision = item.sku == null
            ? const <Map<String, Object?>>[]
            : await transaction.query(
                'catalog_items',
                where:
                    'organization_id = ? AND branch_id = ? AND sku = ? '
                    'AND id <> ?',
                whereArgs: <Object?>[
                  organizationId,
                  branchId,
                  item.sku,
                  item.id,
                ],
                limit: 1,
              );
        if (skuCollision.isNotEmpty) {
          final collidingId = skuCollision.single['id']! as String;
          await transaction.update(
            'catalog_items',
            <String, Object?>{
              'is_active': 0,
              'sync_state': 'conflict',
              'updated_at': now,
            },
            where: 'id = ? AND organization_id = ? AND branch_id = ?',
            whereArgs: <Object?>[collidingId, organizationId, branchId],
          );
          if (existing != null) {
            await transaction.update(
              'catalog_items',
              <String, Object?>{
                'is_active': 0,
                'sync_state': 'conflict',
                'updated_at': now,
              },
              where: 'id = ? AND organization_id = ? AND branch_id = ?',
              whereArgs: <Object?>[item.id, organizationId, branchId],
            );
          }
          conflicts
            ..add(collidingId)
            ..add(item.id);
          continue;
        }

        final remoteValues = item.toLocalRow(syncState: 'synced');
        if (existing == null) {
          await transaction.insert('catalog_items', remoteValues);
          inserted++;
          continue;
        }

        final localSyncState = existing['sync_state']! as String;
        final fieldsMatch = item.matchesLocalRow(existing);
        if (localSyncState != 'synced' && !fieldsMatch) {
          // Keep unsynced local values for review, but fail closed so the item
          // is not offered for new sales until its identity/price is reconciled.
          await transaction.update(
            'catalog_items',
            <String, Object?>{
              'is_active': 0,
              'sync_state': 'conflict',
              'updated_at': now,
            },
            where: 'id = ? AND organization_id = ? AND branch_id = ?',
            whereArgs: <Object?>[item.id, organizationId, branchId],
          );
          conflicts.add(item.id);
          continue;
        }

        final changed = !fieldsMatch || localSyncState != 'synced';
        await transaction.update(
          'catalog_items',
          remoteValues,
          where: 'id = ? AND organization_id = ? AND branch_id = ?',
          whereArgs: <Object?>[item.id, organizationId, branchId],
        );
        if (changed) updated++;
      }

      return CloudCatalogSyncResult(
        received: remoteItems.length,
        inserted: inserted,
        updated: updated,
        deactivated: deactivated,
        conflictItemIds: conflicts,
      );
    });
  }

  String _timestamp() => _clock().toUtc().toIso8601String();

  static void _validateUniqueRemoteItems(List<_CloudCatalogItem> items) {
    final ids = <String>{};
    final skuOwners = <String, String>{};
    for (final item in items) {
      if (!ids.add(item.id)) {
        throw FormatException('Duplicate cloud catalog UUID: ${item.id}');
      }
      final sku = item.sku;
      if (sku != null) {
        final priorOwner = skuOwners[sku];
        if (priorOwner != null && priorOwner != item.id) {
          throw FormatException('Duplicate cloud SKU "$sku" in one branch.');
        }
        skuOwners[sku] = item.id;
      }
    }
  }

  static void _validateUuid(String value, String field) {
    if (!Uuid.isValidUUIDFormat(fromString: value)) {
      throw ArgumentError.value(value, field, 'must be a UUID');
    }
  }
}

class _CloudCatalogItem {
  const _CloudCatalogItem({
    required this.id,
    required this.organizationId,
    required this.branchId,
    required this.name,
    required this.sku,
    required this.categoryName,
    required this.priceMinor,
    required this.currencyCode,
    required this.isActive,
    required this.updatedAt,
  });

  final String id;
  final String organizationId;
  final String branchId;
  final String name;
  final String? sku;
  final String? categoryName;
  final int priceMinor;
  final String currencyCode;
  final bool isActive;
  final String updatedAt;

  factory _CloudCatalogItem.fromRow(
    Map<String, Object?> row, {
    required String organizationId,
    required String branchId,
  }) {
    final id = _requiredString(row, 'id');
    final rowOrganizationId = _requiredString(row, 'organization_id');
    final rowBranchId = _requiredString(row, 'branch_id');
    if (!Uuid.isValidUUIDFormat(fromString: id) ||
        !Uuid.isValidUUIDFormat(fromString: rowOrganizationId) ||
        !Uuid.isValidUUIDFormat(fromString: rowBranchId)) {
      throw const FormatException('Cloud catalog contains an invalid UUID.');
    }
    if (rowOrganizationId != organizationId || rowBranchId != branchId) {
      throw const FormatException(
        'Cloud catalog returned an item outside the selected branch.',
      );
    }

    final name = _requiredString(row, 'name').trim();
    if (name.isEmpty || name.length > 160) {
      throw const FormatException('Cloud catalog item has an invalid name.');
    }
    final sku = _optionalString(row, 'sku');
    final categoryName = _optionalString(row, 'category_name');
    final priceMinor = _requiredInteger(row['price_minor'], 'price_minor');
    if (priceMinor < 0 || priceMinor > 1000000000) {
      throw const FormatException('Cloud catalog price is outside the supported range.');
    }
    final currencyCode = _requiredString(row, 'currency_code');
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currencyCode)) {
      throw const FormatException(
        'Cloud catalog currency must be three uppercase letters.',
      );
    }
    final active = row['is_active'];
    if (active is! bool) {
      throw const FormatException('Cloud catalog activity flag must be boolean.');
    }
    final rawUpdatedAt = _requiredString(row, 'updated_at');
    final parsedUpdatedAt = DateTime.tryParse(rawUpdatedAt);
    if (parsedUpdatedAt == null) {
      throw const FormatException('Cloud catalog updated_at is invalid.');
    }

    return _CloudCatalogItem(
      id: id,
      organizationId: rowOrganizationId,
      branchId: rowBranchId,
      name: name,
      sku: sku,
      categoryName: categoryName,
      priceMinor: priceMinor,
      currencyCode: currencyCode,
      isActive: active,
      updatedAt: parsedUpdatedAt.toUtc().toIso8601String(),
    );
  }

  Map<String, Object?> toLocalRow({required String syncState}) =>
      <String, Object?>{
        'id': id,
        'organization_id': organizationId,
        'branch_id': branchId,
        'name': name,
        'sku': sku,
        'category_name': categoryName,
        'price_minor': priceMinor,
        'currency_code': currencyCode,
        'is_active': isActive ? 1 : 0,
        'updated_at': updatedAt,
        'sync_state': syncState,
      };

  bool matchesLocalRow(Map<String, Object?> row) =>
      row['id'] == id &&
      row['organization_id'] == organizationId &&
      row['branch_id'] == branchId &&
      row['name'] == name &&
      row['sku'] == sku &&
      row['category_name'] == categoryName &&
      row['price_minor'] == priceMinor &&
      row['currency_code'] == currencyCode &&
      row['is_active'] == (isActive ? 1 : 0);

  static String _requiredString(Map<String, Object?> row, String field) {
    final value = row[field];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Cloud catalog field "$field" is missing.');
    }
    return value;
  }

  static String? _optionalString(Map<String, Object?> row, String field) {
    final value = row[field];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Cloud catalog field "$field" is invalid.');
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static int _requiredInteger(Object? value, String field) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.toInt()) {
      return value.toInt();
    }
    throw FormatException('Cloud catalog field "$field" must be an integer.');
  }
}
