import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/domain/holiday_calendar.dart';

void main() {
  test('范围跳过周末，首末日半天按天计费', () {
    final slots = buildAnnualLeaveSlots(
      start: DateTime(2026, 8, 7),
      end: DateTime(2026, 8, 10),
      startAfternoon: true,
      endMorning: true,
      calendar: HolidayCalendar(HolidayCalendar.defaults2026),
      supportedYears: {2026},
    );
    expect(slots.map((s) => '${s.date}/${s.period}'), [
      '2026-08-07/pm',
      '2026-08-10/am',
    ]);
    expect(slots.length / 2, 1);
    expect(slots.first.overlaps('11:30', '12:00'), isFalse);
    expect(slots.first.overlaps('12:00', '13:00'), isTrue);
  });
  test('跨年、未知日历和休息日半天均拒绝', () {
    List<AnnualLeaveSlot> build(DateTime start, DateTime end) =>
        buildAnnualLeaveSlots(
          start: start,
          end: end,
          calendar: HolidayCalendar(HolidayCalendar.defaults2026),
          supportedYears: {2026},
        );
    expect(
      () => build(DateTime(2026, 12, 31), DateTime(2027, 1, 1)),
      throwsStateError,
    );
    expect(
      () => build(DateTime(2027, 1, 4), DateTime(2027, 1, 4)),
      throwsStateError,
    );
    expect(
      () => build(DateTime(2026, 8, 8), DateTime(2026, 8, 8)),
      throwsStateError,
    );
    final makeup = build(DateTime(2026, 10, 10), DateTime(2026, 10, 10));
    expect(makeup.length, 2);
  });

  test('额度按所属年计算，过期结余不会计入当前可用', () {
    final record = AnnualLeaveRecord(
      id: 'a',
      startDate: '2026-08-03',
      endDate: '2026-08-03',
      slots: const [AnnualLeaveSlot('2026-08-03', 'pm')],
      createdAt: '2026-08-01T00:00:00Z',
    );
    final old = AnnualLeaveBalance(2026, [record], now: DateTime(2027));
    expect(old.usedDays, 0.5);
    expect(old.remainingDays, 4.5);
    expect(old.availableDays, 0);
    expect(
      AnnualLeaveBalance(2027, [record], now: DateTime(2027)).availableDays,
      5,
    );
    final quota = AnnualLeaveRecord(
      id: 'all',
      startDate: '2026-08-03',
      endDate: '2026-08-07',
      slots: buildAnnualLeaveSlots(
        start: DateTime(2026, 8, 3),
        end: DateTime(2026, 8, 7),
        calendar: HolidayCalendar(HolidayCalendar.defaults2026),
        supportedYears: {2026},
      ),
      createdAt: '2026-08-01T00:00:00Z',
    );
    expect(() => validateAnnualLedger([quota, record], []), throwsA(anything));
  });
}
