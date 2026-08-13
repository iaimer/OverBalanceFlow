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
