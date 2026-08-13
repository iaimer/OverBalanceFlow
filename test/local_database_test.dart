import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
