import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/domain/ledger_validator.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:over_balance_flow/data/migration_service.dart';
import 'package:over_balance_flow/data/data_fingerprint.dart';

void main() {
  test('完整 FIFO 账本通过一致性校验', () {
    expect(
      () => LedgerValidator.validate([
        overtime(remaining: 1, status: '部分核销'),
        leave('ot-1', 2),
      ]),
      returnsNormally,
    );
  });

  test('悬空调休引用阻断迁移或恢复', () {
    expect(
      () => LedgerValidator.validate([leave('missing', 1)]),
      throwsFormatException,
    );
  });

  test('余额与核销历史不一致时阻断迁移或恢复', () {
    expect(
      () => LedgerValidator.validate([
        overtime(remaining: 2, status: '部分核销'),
        leave('ot-1', 2),
      ]),
      throwsFormatException,
    );
  });

  test('调休存根 totalHours 或余额不合法时阻断', () {
    final broken = leave('ot-1', 1).copyWith(remainingHours: 1);
    expect(
      () => LedgerValidator.validate([
        overtime(remaining: 2, status: '部分核销'),
        broken,
      ]),
      throwsFormatException,
    );
  });

  test('历史记录缺少 created_at 时拒绝反序列化', () {
    final map = overtime(remaining: 3, status: '待核销').toMap()
      ..remove('created_at');
    expect(() => OvertimeRecord.fromMap(map), throwsFormatException);
  });

  test('外部基线不一致时阻断迁移', () {
    const baseline = ExpectedBaseline(
      recordCount: 1,
      recordsSha256: 'wrong',
      uuidSha256: 'wrong',
      photoCount: 0,
      photoBindings: {},
    );
    expect(
      () => baseline.verify(
        DataFingerprint.fromRecords([overtime(remaining: 3, status: '待核销')]),
      ),
      throwsStateError,
    );
  });

  test('照片路径与记录 UUID 对调时阻断迁移', () {
    final first = overtime(
      remaining: 3,
      status: '待核销',
    ).copyWith(photoPath: 'remote/first.jpg');
    final second = OvertimeRecord(
      id: 'ot-2',
      otDate: '2026-01-02',
      startTime: '17:00',
      endTime: '20:00',
      duration: 3,
      totalHours: 3,
      remainingHours: 3,
      status: '待核销',
      memo: '',
      photoPath: 'remote/second.jpg',
      createdAt: '2026-01-02T00:00:00Z',
    );
    const baseline = ExpectedBaseline(
      recordCount: 2,
      recordsSha256: 'unused',
      uuidSha256: 'unused',
      photoCount: 2,
      photoBindings: {
        'ot-1': PhotoBaseline(
          remotePath: 'remote/second.jpg',
          sha256: 'hash-1',
        ),
        'ot-2': PhotoBaseline(remotePath: 'remote/first.jpg', sha256: 'hash-2'),
      },
    );
    expect(() => baseline.verifyRecords([first, second]), throwsStateError);
  });
}

OvertimeRecord overtime({required double remaining, required String status}) =>
    OvertimeRecord(
      id: 'ot-1',
      otDate: '2026-01-01',
      startTime: '17:00',
      endTime: '20:00',
      duration: 3,
      totalHours: 3,
      remainingHours: remaining,
      status: status,
      memo: '',
      createdAt: '2026-01-01T00:00:00Z',
    );

OvertimeRecord leave(String target, double deduct) => OvertimeRecord(
  id: 'leave-1',
  otDate: '2026-02-01',
  startTime: '09:00',
  endTime: '11:00',
  duration: -deduct,
  totalHours: -deduct,
  remainingHours: 0,
  status: '已调休',
  memo: jsonEncode([
    {'id': target, 'deduct': deduct, 'info': 'test'},
  ]),
  createdAt: '2026-02-01T00:00:00Z',
);
