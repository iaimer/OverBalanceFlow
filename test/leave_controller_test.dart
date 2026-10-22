import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/app_controller.dart';
import 'package:over_balance_flow/data/local_database.dart';
import 'package:over_balance_flow/data/supabase_repository.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory root;
  late LocalDatabase db;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('obf-leave-controller-');
    db = await LocalDatabase.open(
      databasePath: '${root.path}/db',
      rootDirectory: root,
    );
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('云端未确认年假前不改缓存，确认后余额与记录同时更新', () async {
    final remote = LeaveRemote()..confirmation = Completer<void>();
    final controller = AppController(db, remoteOverride: remote);
    final preview = controller.previewAnnualLeave(
      startDate: DateTime(2026, 8, 3),
      endDate: DateTime(2026, 8, 3),
      singlePeriod: 'am',
    );
    final saving = controller.saveAnnualLeave(preview);
    await Future<void>.delayed(Duration.zero);
    expect(await db.annualRecords(), isEmpty);
    expect(controller.annualRecords, isEmpty);
    remote.confirmation!.complete();
    await saving;
    expect((await db.annualRecords()).single.days, 0.5);
    expect(
      controller.annualBalance(2026, now: DateTime(2026)).availableDays,
      4.5,
    );
  });

  test('云端拒绝写入、空快照或缺日历时保留有效年假缓存', () async {
    final original = annual();
    await db.replaceLedgerCache([], [original], LeaveCalendar.builtin2026);
    final remote = LeaveRemote()
      ..annual = [original]
      ..saveError = StateError('network down');
    final controller = AppController(db, remoteOverride: remote)
      ..annualRecords = [original];
    await expectLater(
      controller.saveAnnualLeave(original, editing: true),
      throwsStateError,
    );
    expect((await db.annualRecords()).single.id, original.id);
    remote.annual = [];
    await expectLater(controller.syncFromCloud(), throwsStateError);
    remote.annual = [original];
    remote.calendar = LeaveCalendar([]);
    await expectLater(controller.syncFromCloud(), throwsStateError);
    expect((await db.annualRecords()).single.id, original.id);
    expect(controller.usingOfflineCache, isTrue);
  });

  test('核销历史不完整的快照不能覆盖有效缓存', () async {
    final original = annual();
    await db.replaceLedgerCache([], [original], LeaveCalendar.builtin2026);
    final remote = LeaveRemote()
      ..annual = [original]
      ..records = [
        OvertimeRecord(
          id: 'broken',
          otDate: '2026-08-01',
          startTime: '08:30',
          endTime: '11:30',
          duration: 3,
          totalHours: 3,
          remainingHours: 1,
          status: '部分核销',
          memo: '',
          createdAt: '2026-08-01T00:00:00Z',
        ),
      ];
    final controller = AppController(db, remoteOverride: remote)
      ..annualRecords = [original];
    await expectLater(
      controller.syncFromCloud(),
      throwsA(isA<FormatException>()),
    );
    expect(await db.records(), isEmpty);
    expect((await db.annualRecords()).single.id, 'a');
  });

  test('已提交但快照失败时明确区分云端成功与缓存失败', () async {
    final remote = LeaveRemote()
      ..fetchError = StateError('offline after commit');
    final controller = AppController(db, remoteOverride: remote);
    await expectLater(
      controller.saveAnnualLeave(annual()),
      throwsA(isA<CloudRefreshException>()),
    );
    expect(remote.annual.single.id, 'a');
    expect(await db.annualRecords(), isEmpty);
  });

  test('调休编辑按返还后余额预览，新增和编辑余额不足均拒绝', () {
    final ot = OvertimeRecord(
      id: 'ot',
      otDate: '2026-08-01',
      startTime: '08:30',
      endTime: '11:30',
      duration: 3,
      totalHours: 3,
      remainingHours: 1,
      status: '部分核销',
      memo: '',
      createdAt: '2026-08-01T00:00:00Z',
    );
    final leave = OvertimeRecord(
      id: 'leave',
      otDate: '2026-08-04',
      startTime: '08:30',
      endTime: '10:30',
      duration: -2,
      totalHours: -2,
      remainingHours: 0,
      status: '已调休',
      memo: jsonEncode([
        {'id': 'ot', 'deduct': 2, 'info': ''},
      ]),
      createdAt: '2026-08-01T00:00:00Z',
    );
    final controller = AppController(db, remoteOverride: LeaveRemote())
      ..records = [ot, leave];
    expect(
      controller
          .previewLeave('08:30', '11:30', editingId: 'leave')
          .deductedHours,
      3,
    );
    expect(() => controller.previewLeave('08:30', '11:30'), throwsStateError);
    expect(
      () => controller.previewLeave('08:30', '13:00', editingId: 'leave'),
      throwsStateError,
    );
    controller.annualRecords = [annual()];
    expect(
      () =>
          controller.previewLeave('08:30', '09:00', date: DateTime(2026, 8, 3)),
      throwsStateError,
    );
    expect(
      () => controller.previewAnnualLeave(
        startDate: DateTime(2026, 8, 4),
        endDate: DateTime(2026, 8, 4),
      ),
      throwsStateError,
    );
  });
}

AnnualLeaveRecord annual() => AnnualLeaveRecord(
  id: 'a',
  startDate: '2026-08-03',
  endDate: '2026-08-03',
  slots: const [AnnualLeaveSlot('2026-08-03', 'am')],
  createdAt: '2026-08-01T00:00:00Z',
);

class LeaveRemote extends SupabaseRepository {
  LeaveRemote()
    : super(const SupabaseConfig('https://example.invalid', 'test'));
  List<AnnualLeaveRecord> annual = [];
  List<OvertimeRecord> records = [];
  LeaveCalendar calendar = LeaveCalendar.builtin2026;
  Completer<void>? confirmation;
  Object? saveError;
  Object? fetchError;
  @override
  Future<LedgerSnapshot> fetchLedger() async {
    if (fetchError != null) throw fetchError!;
    return LedgerSnapshot(records, annual, calendar);
  }

  @override
  Future<void> saveAnnualLeave(
    AnnualLeaveRecord record, {
    required bool allowInsert,
  }) async {
    if (confirmation != null) await confirmation!.future;
    if (saveError != null) throw saveError!;
    annual = [record];
  }
}
