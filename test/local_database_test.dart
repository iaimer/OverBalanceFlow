import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/data/local_database.dart';
import 'package:over_balance_flow/domain/business_rules.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory temp;
  late LocalDatabase database;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('obf-test-');
    database = await LocalDatabase.open(
      databasePath: '${temp.path}/test.db',
      rootDirectory: temp,
    );
  });

  tearDown(() async {
    await database.close();
    await temp.delete(recursive: true);
  });

  test('核销在单一事务中扣减并创建负数存根', () async {
    await database.addRecord(record('ot-1', 3));
    final preview = previewFifo(await database.records(), 2);
    await database.reconcile(
      leaveId: 'leave-1',
      date: '2026-02-01',
      startTime: '09:00',
      endTime: '11:00',
      preview: preview,
      createdAt: '2026-02-01T00:00:00Z',
    );
    final records = await database.records();
    expect(records.firstWhere((item) => item.id == 'ot-1').remainingHours, 1);
    final leave = records.firstWhere((item) => item.id == 'leave-1');
    expect(leave.duration, -2);
    expect(leave.status, '已调休');
  });

  test('删除调休存根后在同一事务返还余额', () async {
    await database.addRecord(record('ot-1', 3));
    final preview = previewFifo(await database.records(), 2);
    await database.reconcile(
      leaveId: 'leave-1',
      date: '2026-02-01',
      startTime: '09:00',
      endTime: '11:00',
      preview: preview,
      createdAt: '2026-02-01T00:00:00Z',
    );
    await database.deleteRecord('leave-1');
    final records = await database.records();
    expect(records.any((item) => item.id == 'leave-1'), isFalse);
    final overtime = records.single;
    expect(overtime.remainingHours, 3);
    expect(overtime.status, '待核销');
  });

  test('已有核销引用的加班不能直接删除', () async {
    await database.addRecord(record('ot-1', 3));
    final preview = previewFifo(await database.records(), 1);
    await database.reconcile(
      leaveId: 'leave-1',
      date: '2026-02-01',
      startTime: '09:00',
      endTime: '10:00',
      preview: preview,
      createdAt: '2026-02-01T00:00:00Z',
    );
    await expectLater(database.deleteRecord('ot-1'), throwsStateError);
    expect((await database.records()).map((item) => item.id).toSet(), {
      'ot-1',
      'leave-1',
    });
  });

  test('返还引用丢失时整个删除事务回滚', () async {
    await database.addRecord(
      OvertimeRecord(
        id: 'leave-broken',
        otDate: '2026-02-01',
        startTime: '09:00',
        endTime: '10:00',
        duration: -1,
        totalHours: -1,
        remainingHours: 0,
        status: '已调休',
        memo: '[{"id":"missing","deduct":1,"info":"missing"}]',
        createdAt: '2026-02-01T00:00:00Z',
      ),
    );
    await expectLater(database.deleteRecord('leave-broken'), throwsStateError);
    expect((await database.records()).single.id, 'leave-broken');
  });

  test('年假与调休缓存一起事务替换且失败时保留原账本', () async {
    final annual = AnnualLeaveRecord(
      id: 'annual-1',
      startDate: '2026-08-03',
      endDate: '2026-08-03',
      slots: const [AnnualLeaveSlot('2026-08-03', 'am')],
      createdAt: '2026-08-01T00:00:00Z',
    );
    await database.replaceLedgerCache(
      [record('safe', 3)],
      [annual],
      LeaveCalendar.builtin2026,
    );
    expect((await database.annualRecords()).single.days, 0.5);
    await expectLater(
      database.replaceLedgerCache(
        [record('duplicate', 1), record('duplicate', 1)],
        [],
        LeaveCalendar.builtin2026,
      ),
      throwsA(anything),
    );
    expect((await database.records()).single.id, 'safe');
    expect((await database.annualRecords()).single.id, 'annual-1');
  });

  test('v1 升级保留历史并先建立可打开的旧版恢复点', () async {
    final oldPath = '${temp.path}/old.db';
    final old = await openDatabase(
      oldPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE ot_records (
        id TEXT PRIMARY KEY, ot_date TEXT, start_time TEXT, end_time TEXT,
        duration REAL, total_hours REAL, remaining_hours REAL, status TEXT,
        memo TEXT, photo_path TEXT, created_at TEXT)''');
        await db.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY,value TEXT)',
        );
        await db.execute(
          'CREATE TABLE holiday_calendar (date TEXT PRIMARY KEY,is_day_off INTEGER,source TEXT,calendar_version TEXT)',
        );
      },
    );
    await old.insert('ot_records', record('historical', 3).toMap());
    await old.insert('settings', {
      'key': 'migration_completed',
      'value': 'true',
    });
    await old.close();
    final upgraded = await LocalDatabase.open(
      databasePath: oldPath,
      rootDirectory: temp,
    );
    try {
      expect((await upgraded.records()).single.id, 'historical');
      expect(await upgraded.setting('migration_completed'), 'true');
      expect((await upgraded.leaveCalendar()).supportedYears, {2026});
      final recovery = temp.listSync().whereType<Directory>().singleWhere(
        (d) => d.path.contains('pre-schema-1-to-2'),
      );
      final restored = await openReadOnlyDatabase(
        '${recovery.path}/database.db',
      );
      expect(await restored.getVersion(), 1);
      expect((await restored.query('ot_records')).single['id'], 'historical');
      await restored.close();
    } finally {
      await upgraded.close();
    }
  });

  test('旧版 App 拒绝降级打开更高版本数据库', () async {
    await database.close();
    final path = '${temp.path}/future.db';
    final future = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: LocalDatabase.schemaVersion + 1,
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE future_data (id TEXT PRIMARY KEY)');
        },
      ),
    );
    await future.close();
    await expectLater(
      LocalDatabase.open(databasePath: path, rootDirectory: temp),
      throwsStateError,
    );
    database = await LocalDatabase.open(
      databasePath: '${temp.path}/test-after-downgrade.db',
      rootDirectory: temp,
    );
  });
}

OvertimeRecord record(String id, double hours) => OvertimeRecord(
  id: id,
  otDate: '2026-01-01',
  startTime: '17:00',
  endTime: '20:00',
  duration: hours,
  totalHours: hours,
  remainingHours: hours,
  status: '待核销',
  memo: '',
  createdAt: '2026-01-01T00:00:00Z',
);
