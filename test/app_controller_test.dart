import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/app_controller.dart';
import 'package:over_balance_flow/data/local_database.dart';
import 'package:over_balance_flow/data/supabase_repository.dart';
import 'package:over_balance_flow/domain/business_rules.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory root;
  late LocalDatabase database;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('obf-controller-');
    database = await LocalDatabase.open(
      databasePath: '${root.path}/test.db',
      rootDirectory: root,
    );
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test('编辑成功后保留历史核销并在云端确认后刷新缓存', () async {
    final target = overtimeRecord(duration: 4, remaining: 1, status: '部分核销');
    final remote = FakeSupabaseRepository();
    final controller = AppController(database, remoteOverride: remote);
    controller.records = [target];

    await controller.updateOvertime(
      id: target.id,
      date: DateTime(2026, 8, 8),
      start: '09:00',
      end: '13:00',
      memo: '修正日期',
    );

    expect(remote.saved, isNotNull);
    expect(remote.saved!.duration, 3.5);
    expect(remote.saved!.remainingHours, 0.5);
    expect(remote.saved!.status, '部分核销');
    expect(remote.lastAllowInsert, isFalse);
    expect(remote.fetchCount, 1);
    final cached = (await database.records()).firstWhere(
      (r) => r.id == target.id,
    );
    expect(cached.toMap(), remote.saved!.toMap());
  });

  test('新增成功只发起一次云端保存并刷新一次缓存', () async {
    final remote = FakeSupabaseRepository()..targetExists = false;
    final controller = AppController(database, remoteOverride: remote);

    await controller.addOvertime(
      date: DateTime(2026, 8, 8),
      start: '09:00',
      end: '13:00',
      memo: '一次新增',
    );

    expect(remote.saveCalls, 1);
    expect(remote.fetchCount, 1);
    expect(controller.records, hasLength(1));
    expect(await database.records(), hasLength(1));
  });

  test('新增同日重叠时间段时在发起云端写入前拒绝', () async {
    final existing = overtimeRecord(duration: 4, remaining: 4, status: '待核销');
    final remote = FakeSupabaseRepository();
    final controller = AppController(database, remoteOverride: remote);
    controller.records = [existing];

    await expectLater(
      controller.addOvertime(
        date: DateTime(2026, 8, 8),
        start: '12:00',
        end: '14:00',
        memo: '重叠记录',
      ),
      throwsA(isA<OvertimeOverlapException>()),
    );

    expect(remote.saved, isNull);
    expect(remote.lastAllowInsert, isNull);
    expect(remote.fetchCount, 0);
  });

  test('编辑时云端记录已删除不会被重新插入', () async {
    final target = overtimeRecord(duration: 4, remaining: 4, status: '待核销');
    final remote = FakeSupabaseRepository()..targetExists = false;
    final controller = AppController(database, remoteOverride: remote);
    controller.records = [target];

    await expectLater(
      controller.updateOvertime(
        id: target.id,
        date: DateTime(2026, 8, 8),
        start: '09:00',
        end: '12:00',
        memo: '云端已删除',
      ),
      throwsStateError,
    );

    expect(remote.saved, isNull);
    expect(remote.fetchCount, 0);
  });

  test('云端保存失败时不刷新或修改本地缓存', () async {
    final target = overtimeRecord(duration: 4, remaining: 4, status: '待核销');
    await database.addRecord(target);
    final remote = FakeSupabaseRepository()
      ..saveError = const HttpException('network down');
    final controller = AppController(database, remoteOverride: remote);
    controller.records = [target];

    await expectLater(
      controller.updateOvertime(
        id: target.id,
        date: DateTime(2026, 8, 8),
        start: '09:00',
        end: '12:00',
        memo: '不应落库',
      ),
      throwsA(isA<HttpException>()),
    );

    expect(remote.fetchCount, 0);
    expect((await database.records()).single.toMap(), target.toMap());
    expect(controller.records.single.toMap(), target.toMap());
  });
}

class FakeSupabaseRepository extends SupabaseRepository {
  FakeSupabaseRepository()
    : super(const SupabaseConfig('https://example.invalid', 'test-key'));

  OvertimeRecord? saved;
  Object? saveError;
  bool? lastAllowInsert;
  bool targetExists = true;
  int fetchCount = 0;
  int saveCalls = 0;

  @override
  Future<LedgerSnapshot> fetchLedger() async {
    fetchCount++;
    final current = saved;
    return LedgerSnapshot(
      current == null
          ? const []
          : [
              current,
              if (current.duration > current.remainingHours)
                OvertimeRecord(
                  id: 'historical-leave',
                  otDate: '2026-08-09',
                  startTime: '08:30',
                  endTime: '11:30',
                  duration: current.remainingHours - current.duration,
                  totalHours: current.remainingHours - current.duration,
                  remainingHours: 0,
                  status: '已调休',
                  memo: jsonEncode([
                    {
                      'id': current.id,
                      'deduct': current.duration - current.remainingHours,
                      'info': '',
                    },
                  ]),
                  createdAt: '2026-08-09T00:00:00Z',
                ),
            ],
      [],
      LeaveCalendar.builtin2026,
    );
  }

  @override
  Future<void> saveOvertimeAtomically(
    OvertimeRecord record, {
    required bool allowInsert,
  }) async {
    saveCalls++;
    final error = saveError;
    if (error != null) throw error;
    if (!allowInsert && !targetExists) {
      throw StateError('待编辑记录不存在');
    }
    if (allowInsert && targetExists) {
      throw StateError('新增记录 ID 已存在');
    }
    lastAllowInsert = allowInsert;
    targetExists = true;
    saved = record;
  }
}

OvertimeRecord overtimeRecord({
  required double duration,
  required double remaining,
  required String status,
}) => OvertimeRecord(
  id: 'ot-edit-1',
  otDate: '2026-08-08',
  startTime: '09:00',
  endTime: '13:00',
  duration: duration,
  totalHours: duration,
  remainingHours: remaining,
  status: status,
  memo: '原备注',
  createdAt: '2026-08-08T10:00:00Z',
);
