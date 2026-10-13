import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:mizzy/core/database/mizzy_database.dart';
import 'package:mizzy/features/tables/data/cloud_table_repository.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());
  late MizzyDatabase database;
  late _FakeTables source;
  late CloudTableRepository repository;
  late String organizationId, branchId;
  late DateTime now;

  setUp(() {
    organizationId = const Uuid().v4();
    branchId = const Uuid().v4();
    now = DateTime.utc(2026, 10, 14, 12);
    database = MizzyDatabase(factory: databaseFactoryFfi, databaseName: 'cloud-tables-${const Uuid().v4()}.db');
    source = _FakeTables();
    repository = CloudTableRepository(
      database: database, source: source, hasBranchAccess: _allow, clock: () => now,
    );
  });
  tearDown(() => database.close());

  Map<String,Object?> table({String? id,String? org,String? branch,String name='A1',String status='available',bool active=true}) => {
    'id':id ?? const Uuid().v4(), 'organization_id':org ?? organizationId,
    'branch_id':branch ?? branchId, 'name':name, 'area_name':'Main Hall',
    'capacity':4, 'status':status, 'is_active':active, 'updated_at':now.toIso8601String(),
  };
  Future<Map<String,Object?>> readTable(String id) async {
    final db=await database.open();
    return (await db.query('restaurant_tables',where:'id = ? AND organization_id = ? AND branch_id = ?',whereArgs:[id,organizationId,branchId],limit:1)).single;
  }

  test('branch access is checked before remote requests', () async {
    var calls=0;
    final denied=CloudTableRepository(database:database,source:_CountingTables(()=>calls++),hasBranchAccess:_deny,clock:()=>now);
    await expectLater(denied.syncBranch(organizationId:organizationId,branchId:branchId),throwsStateError);
    expect(calls,0);
    expect(await (await database.open()).query('restaurant_tables'),isEmpty);
  });

  test('imports real UUIDs and disables inactive tables', () async {
    final a=table(id:const Uuid().v4()), b=table(id:const Uuid().v4(),name:'Patio',active:false);
    source.rows=[a,b];
    final result=await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    expect(result.inserted,2);
    expect((await readTable(a['id']! as String))['status'],'available');
    expect((await readTable(b['id']! as String))['status'],'inactive');
  });

  test('updates remote occupancy for a synchronized table', () async {
    final id=const Uuid().v4(); source.rows=[table(id:id)];
    await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    source.rows=[table(id:id,status:'occupied')];
    await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    expect((await readTable(id))['status'],'occupied');
  });

  test('preserves pending local reservation when cloud is stale', () async {
    final id=const Uuid().v4(); source.rows=[table(id:id)];
    await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    final db=await database.open();
    await db.update('restaurant_tables',{'status':'occupied','sync_state':'pending'},where:'id = ?',whereArgs:[id]);
    source.rows=[table(id:id,status:'available')];
    await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    final saved=await readTable(id);
    expect(saved['status'],'occupied'); expect(saved['sync_state'],'pending');
  });

  test('remote competing reservation blocks local availability', () async {
    final id=const Uuid().v4(); source.rows=[table(id:id)];
    await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    final db=await database.open();
    await db.update('restaurant_tables',{'status':'available','sync_state':'pending'},where:'id = ?',whereArgs:[id]);
    source.rows=[table(id:id,status:'occupied')];
    final result=await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    final saved=await readTable(id);
    expect(result.conflictTableIds,contains(id));
    expect(saved['status'],'occupied'); expect(saved['sync_state'],'conflict');
  });

  test('removed tables are retained but inactive', () async {
    final id=const Uuid().v4(); source.rows=[table(id:id)];
    await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    source.rows=[];
    final result=await repository.syncBranch(organizationId:organizationId,branchId:branchId);
    expect(result.deactivated,1); expect((await readTable(id))['status'],'inactive');
  });

  test('rejects foreign branch rows before mutation', () async {
    source.rows=[table(branch:const Uuid().v4())];
    await expectLater(repository.syncBranch(organizationId:organizationId,branchId:branchId),throwsFormatException);
    expect(await (await database.open()).query('restaurant_tables'),isEmpty);
  });

  test('remote source rejects missing auth session', () async {
    final client=SupabaseClient('https://example.supabase.co','test-publishable-key');
    final remote=SupabaseCloudTableSource(client:client);
    await expectLater(remote.fetchBranchTables(organizationId:organizationId,branchId:branchId),throwsStateError);
  });
}

Future<bool> _allow({required String organizationId,required String branchId}) async => true;
Future<bool> _deny({required String organizationId,required String branchId}) async => false;
class _FakeTables implements CloudTableSource {
  List<Map<String,Object?>> rows=[];
  @override
  Future<List<Map<String,Object?>>> fetchBranchTables({required String organizationId,required String branchId}) async => rows.map((r)=>Map<String,Object?>.from(r)).toList();
}
class _CountingTables implements CloudTableSource {
  _CountingTables(this.onCall); final void Function() onCall;
  @override
  Future<List<Map<String,Object?>>> fetchBranchTables({required String organizationId,required String branchId}) async {onCall(); return const [];}
}
