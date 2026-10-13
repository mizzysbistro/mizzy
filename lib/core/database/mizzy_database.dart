import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:uuid/uuid.dart';

/// Owns the on-device SQLite database and its versioned schema.
///
/// A device database is a cache/queue for one installation. It is not an
/// authorization boundary; tenant and branch authorization must also be
/// enforced by Supabase RLS and trusted backend workflows.
class MizzyDatabase {
  MizzyDatabase({
    sqflite.DatabaseFactory? factory,
    this.databaseName = 'mizzy.db',
  }) : _factory = factory ?? sqflite.databaseFactory;

  final sqflite.DatabaseFactory _factory;
  final String databaseName;
  Future<sqflite.Database>? _databaseFuture;

  static const int schemaVersion = 2;

  Future<sqflite.Database> open() {
    final cached = _databaseFuture;
    if (cached != null) {
      return cached;
    }

    final opening = _open().catchError((Object error, StackTrace stackTrace) {
      _databaseFuture = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _databaseFuture = opening;
    return opening;
  }

  Future<sqflite.Database> _open() async {
    final directory = await _factory.getDatabasesPath();
    final databasePath = p.join(directory, databaseName);
    return _factory.openDatabase(
      databasePath,
      options: sqflite.OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (database, version) => _createSchema(database),
        onUpgrade: _upgradeSchema,
      ),
    );
  }

  Future<void> close() async {
    final cached = _databaseFuture;
    _databaseFuture = null;
    if (cached != null) {
      await (await cached).close();
    }
  }

  /// Returns a stable installation ID, persisted even before cloud sign-in.
  Future<String> installationId() async {
    final database = await open();
    return database.transaction((transaction) async {
      final rows = await transaction.query(
        'local_meta',
        columns: <String>['meta_value'],
        where: 'meta_key = ?',
        whereArgs: <Object?>['installation_id'],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return rows.single['meta_value']! as String;
      }

      final installationId = const Uuid().v4();
      await transaction.insert('local_meta', <String, Object?>{
        'meta_key': 'installation_id',
        'meta_value': installationId,
      });
      return installationId;
    });
  }

  static Future<void> _createSchema(sqflite.Database database) async {
    for (final statement in _schemaStatements) {
      await database.execute(statement);
    }
    await database.insert('local_meta', <String, Object?>{
      'meta_key': 'schema_version',
      'meta_value': schemaVersion.toString(),
    });
  }

  static Future<void> _upgradeSchema(
    sqflite.Database database,
    int oldVersion,
    int newVersion,
  ) async {
    // Add one explicit, transactional migration for each new database version.
    // Never drop user order or payment data as a recovery shortcut.
    if (oldVersion < 1 && newVersion >= 1) {
      await _createSchema(database);
    }
    if (oldVersion < 2 && newVersion >= 2) {
      final columns = await database.rawQuery('PRAGMA table_info(sync_outbox)');
      final hasDependencyColumn = columns.any(
        (column) => column['name'] == 'depends_on_event_id',
      );
      if (!hasDependencyColumn) {
        await database.execute(
          'ALTER TABLE sync_outbox ADD COLUMN depends_on_event_id TEXT '
          'REFERENCES sync_outbox(id)',
        );
      }
      await database.execute(
        'CREATE INDEX IF NOT EXISTS outbox_dependency_idx '
        'ON sync_outbox (depends_on_event_id, status)',
      );
      await database.update(
        'local_meta',
        <String, Object?>{'meta_value': schemaVersion.toString()},
        where: 'meta_key = ?',
        whereArgs: <Object?>['schema_version'],
      );
    }
  }

  static const List<String> _schemaStatements = <String>[
    r'''
      CREATE TABLE local_meta (
        meta_key TEXT PRIMARY KEY NOT NULL,
        meta_value TEXT NOT NULL
      )
    ''',
    r'''
      CREATE TABLE restaurant_tables (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
        area_name TEXT,
        capacity INTEGER NOT NULL DEFAULT 2 CHECK (capacity > 0),
        status TEXT NOT NULL DEFAULT 'available'
          CHECK (status IN ('available', 'occupied', 'reserved', 'inactive')),
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('local', 'pending', 'synced', 'failed', 'conflict')),
        UNIQUE (organization_id, branch_id, name)
      )
    ''',
    r'''
      CREATE TABLE catalog_items (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        name TEXT NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 160),
        sku TEXT,
        category_name TEXT,
        price_minor INTEGER NOT NULL CHECK (price_minor >= 0),
        currency_code TEXT NOT NULL
          CHECK (length(currency_code) = 3 AND currency_code = upper(currency_code)),
        is_active INTEGER NOT NULL DEFAULT 1 CHECK (is_active IN (0, 1)),
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('local', 'pending', 'synced', 'failed', 'conflict')),
        UNIQUE (organization_id, branch_id, sku)
      )
    ''',
    r'''
      CREATE TABLE orders (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        local_order_number INTEGER NOT NULL CHECK (local_order_number > 0),
        device_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'saved'
          CHECK (status IN ('saved', 'preparing', 'ready', 'served', 'completed', 'cancelled')),
        order_type TEXT NOT NULL
          CHECK (order_type IN ('dine_in', 'takeaway', 'delivery')),
        table_id TEXT REFERENCES restaurant_tables(id) ON DELETE SET NULL,
        subtotal_minor INTEGER NOT NULL CHECK (subtotal_minor >= 0),
        tax_minor INTEGER NOT NULL CHECK (tax_minor >= 0),
        discount_minor INTEGER NOT NULL CHECK (discount_minor >= 0),
        total_minor INTEGER NOT NULL CHECK (total_minor >= 0),
        currency_code TEXT NOT NULL
          CHECK (length(currency_code) = 3 AND currency_code = upper(currency_code)),
        note TEXT,
        opened_by TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('local', 'pending', 'synced', 'failed', 'conflict')),
        server_version INTEGER NOT NULL DEFAULT 0 CHECK (server_version >= 0),
        idempotency_key TEXT NOT NULL UNIQUE,
        request_fingerprint TEXT NOT NULL,
        UNIQUE (organization_id, branch_id, device_id, local_order_number)
      )
    ''',
    r'''
      CREATE TABLE order_lines (
        id TEXT PRIMARY KEY NOT NULL,
        order_id TEXT NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
        catalog_item_id TEXT,
        item_name_snapshot TEXT NOT NULL CHECK (length(trim(item_name_snapshot)) > 0),
        sku_snapshot TEXT,
        quantity_milli INTEGER NOT NULL CHECK (quantity_milli > 0),
        unit_price_minor INTEGER NOT NULL CHECK (unit_price_minor >= 0),
        discount_minor INTEGER NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
        tax_minor INTEGER NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),
        line_total_minor INTEGER NOT NULL CHECK (line_total_minor >= 0),
        created_at TEXT NOT NULL
      )
    ''',
    r'''
      CREATE TABLE kitchen_tickets (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        order_id TEXT NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE,
        status TEXT NOT NULL DEFAULT 'queued'
          CHECK (status IN ('queued', 'preparing', 'ready', 'served', 'cancelled')),
        fired_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('local', 'pending', 'synced', 'failed', 'conflict'))
      )
    ''',
    r'''
      CREATE TABLE payments (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        order_id TEXT NOT NULL REFERENCES orders(id) ON DELETE RESTRICT,
        method TEXT NOT NULL
          CHECK (method IN ('cash', 'card', 'qr', 'ewallet', 'other')),
        status TEXT NOT NULL
          CHECK (status IN ('pending', 'authorized', 'captured', 'failed', 'voided', 'refunded')),
        amount_minor INTEGER NOT NULL CHECK (amount_minor > 0),
        currency_code TEXT NOT NULL
          CHECK (length(currency_code) = 3 AND currency_code = upper(currency_code)),
        idempotency_key TEXT NOT NULL UNIQUE,
        provider_transaction_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('local', 'pending', 'synced', 'failed', 'conflict')),
        CHECK (
          status <> 'captured'
          OR method = 'cash'
          OR provider_transaction_id IS NOT NULL
        )
      )
    ''',
    r'''
      CREATE TABLE inventory_movements (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        item_id TEXT NOT NULL,
        item_type TEXT NOT NULL CHECK (item_type IN ('product', 'ingredient')),
        quantity_milli INTEGER NOT NULL CHECK (quantity_milli <> 0),
        unit_name TEXT NOT NULL,
        reason TEXT NOT NULL
          CHECK (reason IN ('receipt', 'sale', 'void', 'waste', 'adjustment', 'transfer')),
        source_entity_type TEXT,
        source_entity_id TEXT,
        actor_id TEXT,
        created_at TEXT NOT NULL,
        sync_state TEXT NOT NULL DEFAULT 'pending'
          CHECK (sync_state IN ('local', 'pending', 'synced', 'failed', 'conflict'))
      )
    ''',
    r'''
      CREATE TABLE sync_outbox (
        id TEXT PRIMARY KEY NOT NULL,
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete', 'transition')),
        schema_version INTEGER NOT NULL DEFAULT 1 CHECK (schema_version > 0),
        payload_json TEXT NOT NULL,
        idempotency_key TEXT NOT NULL UNIQUE,
        depends_on_event_id TEXT REFERENCES sync_outbox(id),
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK (status IN ('pending', 'processing', 'done', 'failed', 'conflict')),
        attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
        next_attempt_at TEXT,
        last_error TEXT,
        created_at TEXT NOT NULL
      )
    ''',
    r'''
      CREATE TABLE sync_cursors (
        organization_id TEXT NOT NULL,
        branch_id TEXT NOT NULL,
        stream_name TEXT NOT NULL,
        cursor_value TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (organization_id, branch_id, stream_name)
      )
    ''',
    'CREATE INDEX orders_branch_status_created_idx ON orders (organization_id, branch_id, status, created_at DESC)',
    'CREATE INDEX order_lines_order_idx ON order_lines (order_id)',
    'CREATE INDEX kitchen_tickets_branch_status_idx ON kitchen_tickets (organization_id, branch_id, status, fired_at)',
    'CREATE INDEX outbox_ready_idx ON sync_outbox (status, next_attempt_at, created_at)',
    'CREATE INDEX outbox_dependency_idx ON sync_outbox (depends_on_event_id, status)',
    'CREATE INDEX inventory_branch_item_created_idx ON inventory_movements (organization_id, branch_id, item_id, created_at DESC)',
  ];
}
