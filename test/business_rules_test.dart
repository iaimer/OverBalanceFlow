import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/domain/business_rules.dart';
import 'package:over_balance_flow/domain/holiday_calendar.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';

void main() {
  group('parseDuration', () {
    test('工作日结束早于 18:00 不计入', () {
      expect(parseDuration('17:00', '17:59'), 0);
    });

    test('工作日从 17:00 起算并向下取整半小时', () {
      expect(parseDuration('16:00', '18:40'), 1.5);
    });

    test('休息日跳过 18:00 限制并扣除午休', () {
      expect(parseDuration('10:00', '13:00', isDayOff: true), 2.5);
    });

    test('23:59 按 24:00 处理', () {
      expect(parseDuration('22:00', '23:59', isDayOff: true), 2);
    });
  });

  test('FIFO 使用日期、创建时间和 UUID 稳定排序', () {
    final records = [
      record('b', '2026-01-02', '2026-01-02T10:00:00Z', 1),
      record('c', '2026-01-01', '2026-01-01T11:00:00Z', 2),
      record('a', '2026-01-01', '2026-01-01T10:00:00Z', 1),
    ];
    final preview = previewFifo(records, 2.5);
    expect(preview.details.map((item) => item.id), ['a', 'c']);
    expect(preview.details.map((item) => item.deduct), [1, 1.5]);
    expect(preview.shortage, 0);
  });

  test('余额不足时只核销现有余额并报告缺口', () {
    final preview = previewFifo([record('a', '2026-01-01', 'x', 1)], 3);
    expect(preview.deductedHours, 1);
    expect(preview.shortage, 2);
  });

  test('官方调休工作日覆盖周末，法定假日与普通周末可区分', () {
    final calendar = HolidayCalendar(HolidayCalendar.defaults2026);
    expect(calendar.dayType(DateTime(2026, 2, 14)), DayType.workday);
    expect(calendar.isDayOff(DateTime(2026, 2, 22)), isTrue);
    expect(calendar.dayType(DateTime(2026, 2, 22)), DayType.statutoryHoliday);
    expect(calendar.dayType(DateTime(2026, 3, 7)), DayType.weekend);
  });

  group('加班时间重叠', () {
    test('部分交叉和包含关系算重叠，首尾相接不算', () {
      expect(
        overtimeIntervalsOverlap(
          firstStart: '18:00',
          firstEnd: '20:00',
          secondStart: '19:30',
          secondEnd: '21:00',
        ),
        isTrue,
      );
      expect(
        overtimeIntervalsOverlap(
          firstStart: '18:00',
          firstEnd: '21:00',
          secondStart: '19:00',
          secondEnd: '20:00',
        ),
        isTrue,
      );
      expect(
        overtimeIntervalsOverlap(
          firstStart: '18:00',
          firstEnd: '19:00',
          secondStart: '19:00',
          secondEnd: '20:00',
        ),
        isFalse,
      );
    });

    test('只查找同一天的加班记录，并排除当前编辑对象和调休记录', () {
      final records = [
        record('same-day', '2026-07-20', '2026-07-20T10:00:00Z', 2),
        OvertimeRecord(
          id: 'other-day',
          otDate: '2026-07-21',
          startTime: '18:00',
          endTime: '20:00',
          duration: 2,
          totalHours: 2,
          remainingHours: 2,
          status: '待核销',
          memo: '',
          createdAt: '2026-07-21T10:00:00Z',
        ),
        OvertimeRecord(
          id: 'leave',
          otDate: '2026-07-20',
          startTime: '18:00',
          endTime: '20:00',
          duration: -2,
          totalHours: -2,
          remainingHours: 0,
          status: '已调休',
          memo: '[]',
          createdAt: '2026-07-20T12:00:00Z',
        ),
      ];

      expect(
        findOverlappingOvertime(
          records,
          date: '2026-07-20',
          startTime: '17:30',
          endTime: '19:00',
        ).map((item) => item.id),
        ['same-day'],
      );
      expect(
        findOverlappingOvertime(
          records,
          date: '2026-07-20',
          startTime: '17:30',
          endTime: '19:00',
          excludingId: 'same-day',
        ),
        isEmpty,
      );
    });
  });

  group('编辑加班余额', () {
    test('编辑已部分核销记录时保留历史核销并重算余额', () {
      final result = calculateOvertimeEditBalance(
        record(
          'partial',
          '2026-07-20',
          '2026-07-20T10:00:00Z',
          4,
        ).copyWith(remainingHours: 1, status: '部分核销'),
        5,
      );

      expect(result.consumedHours, 3);
      expect(result.remainingHours, 2);
      expect(result.status, '部分核销');
    });

    test('编辑已结清记录增加时长后恢复为部分核销', () {
      final result = calculateOvertimeEditBalance(
        record(
          'settled',
          '2026-07-20',
          '2026-07-20T10:00:00Z',
          3,
        ).copyWith(remainingHours: 0, status: '已结清'),
        4,
      );

      expect(result.consumedHours, 3);
      expect(result.remainingHours, 1);
      expect(result.status, '部分核销');
    });

    test('新时长小于历史核销量时拒绝编辑', () {
      expect(
        () => calculateOvertimeEditBalance(
          record(
            'partial',
            '2026-07-20',
            '2026-07-20T10:00:00Z',
            4,
          ).copyWith(remainingHours: 1, status: '部分核销'),
          2.5,
        ),
        throwsA(
          isA<OvertimeDurationException>().having(
            (error) => error.consumedHours,
            'consumedHours',
            3,
          ),
        ),
      );
    });

    test('未核销记录缩短后仍保持待核销状态', () {
      final result = calculateOvertimeEditBalance(
        record('pending', '2026-07-20', '2026-07-20T10:00:00Z', 4),
        2.5,
      );

      expect(result.consumedHours, 0);
      expect(result.remainingHours, 2.5);
      expect(result.status, '待核销');
    });
  });
}

OvertimeRecord record(String id, String date, String createdAt, double hours) =>
    OvertimeRecord(
      id: id,
      otDate: date,
      startTime: '17:00',
      endTime: '18:00',
      duration: hours,
      totalHours: hours,
      remainingHours: hours,
      status: '待核销',
      memo: '',
      createdAt: createdAt,
    );
