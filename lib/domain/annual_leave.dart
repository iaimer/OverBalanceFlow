import 'dart:convert';
import 'dart:math';

import 'business_rules.dart';
import 'holiday_calendar.dart';
import 'overtime_record.dart';

String dateText(DateTime date) => date.toIso8601String().substring(0, 10);
DateTime ledgerDate(String text) {
  final date = DateTime.tryParse(text);
  if (date == null || dateText(date) != text) {
    throw FormatException('无效日期：$text');
  }
  return date;
}

class AnnualLeaveSlot {
  const AnnualLeaveSlot(this.date, this.period);
  final String date;
  final String period;
  String get label => period == 'am' ? '上午' : '下午';
  String get start => period == 'am' ? '08:30' : '12:00';
  String get end => period == 'am' ? '11:30' : '17:00';
  bool overlaps(String startTime, String endTime) => overtimeIntervalsOverlap(
    firstStart: start,
    firstEnd: end,
    secondStart: startTime,
    secondEnd: endTime,
  );
  Map<String, Object> toMap() => {'date': date, 'period': period};
  factory AnnualLeaveSlot.fromMap(Map<String, dynamic> map) {
    final date = map['date'] as String;
    ledgerDate(date);
    final period = map['period'];
    if (period != 'am' && period != 'pm') throw const FormatException('年假时段无效');
    return AnnualLeaveSlot(date, period as String);
  }
}

class AnnualLeaveRecord {
  const AnnualLeaveRecord({
    required this.id,
    required this.startDate,
    required this.endDate,
    required this.slots,
    required this.createdAt,
    this.reason = '',
  });
  final String id;
  final String startDate;
  final String endDate;
  final List<AnnualLeaveSlot> slots;
  final String reason;
  final String createdAt;
  int get year => ledgerDate(startDate).year;
  double get days => slots.length / 2;
  Map<String, Object?> toMap() => {
    'id': id,
    'start_date': startDate,
    'end_date': endDate,
    'slots': slots.map((s) => s.toMap()).toList(),
    'reason': reason,
    'created_at': createdAt,
  };
  Map<String, Object?> toDatabaseMap() => {
    ...toMap(),
    'slots': jsonEncode(slots.map((s) => s.toMap()).toList()),
  };
  factory AnnualLeaveRecord.fromMap(Map<String, dynamic> map) {
    final raw = map['slots'];
    return AnnualLeaveRecord(
      id: map['id'] as String,
      startDate: map['start_date'] as String,
      endDate: map['end_date'] as String,
      slots: ((raw is String ? jsonDecode(raw) : raw) as List<dynamic>)
          .map((s) => AnnualLeaveSlot.fromMap(s as Map<String, dynamic>))
          .toList(),
      reason: map['reason']?.toString() ?? '',
      createdAt: map['created_at'] as String,
    );
  }
}

/// 完整年度才允许登记年假，避免把未知的法定假期当成工作日。
class LeaveCalendar {
  LeaveCalendar(this.rows) {
    final seen = <String>{};
    for (final row in rows) {
      ledgerDate(row['date'] as String);
      if (!seen.add(row['date'] as String) ||
          row['is_day_off'] is! bool ||
          (row['calendar_version'] as String).isEmpty) {
        throw const FormatException('年假日历无效或包含重复日期');
      }
    }
  }
  final List<Map<String, dynamic>> rows;
  Set<int> get supportedYears {
    final counts = <int, int>{};
    for (final row in rows) {
      final year = ledgerDate(row['date'] as String).year;
      counts[year] = (counts[year] ?? 0) + 1;
    }
    return counts.entries
        .where(
          (e) =>
              e.key >= 2026 &&
              e.value == DateTime(e.key + 1).difference(DateTime(e.key)).inDays,
        )
        .map((e) => e.key)
        .toSet();
  }

  HolidayCalendar get holidays => HolidayCalendar({
    for (final row in rows) row['date'] as String: row['is_day_off'] as bool,
  });
  static LeaveCalendar get builtin2026 {
    final calendar = HolidayCalendar(HolidayCalendar.defaults2026);
    return LeaveCalendar([
      for (
        var d = DateTime(2026);
        d.year == 2026;
        d = d.add(const Duration(days: 1))
      )
        {
          'date': dateText(d),
          'is_day_off': calendar.isDayOff(d),
          'calendar_version': '2026.1',
        },
    ]);
  }
}

List<AnnualLeaveSlot> buildAnnualLeaveSlots({
  required DateTime start,
  required DateTime end,
  bool startAfternoon = false,
  bool endMorning = false,
  String singlePeriod = 'full',
  required HolidayCalendar calendar,
  required Set<int> supportedYears,
}) {
  start = DateTime(start.year, start.month, start.day);
  end = DateTime(end.year, end.month, end.day);
  if (start.isAfter(end)) throw StateError('结束日期不能早于开始日期');
  if (start.year != end.year) throw StateError('跨年年假请分两次登记');
  if (start.year < 2026 || !supportedYears.contains(start.year)) {
    throw StateError('${start.year} 年完整日历尚未更新，暂不能登记年假');
  }
  final same = start == end;
  if (!{'full', 'am', 'pm'}.contains(singlePeriod)) throw StateError('年假时段无效');
  if ((same || startAfternoon) && calendar.isDayOff(start) ||
      endMorning && calendar.isDayOff(end)) {
    throw StateError('半天年假和单日年假只能选择工作日');
  }
  final slots = <AnnualLeaveSlot>[];
  for (
    var day = start;
    !day.isAfter(end);
    day = day.add(const Duration(days: 1))
  ) {
    if (calendar.isDayOff(day)) continue;
    final periods = same
        ? (singlePeriod == 'full' ? ['am', 'pm'] : [singlePeriod])
        : day == start && startAfternoon
        ? ['pm']
        : day == end && endMorning
        ? ['am']
        : ['am', 'pm'];
    slots.addAll(periods.map((p) => AnnualLeaveSlot(dateText(day), p)));
  }
  if (slots.isEmpty) throw StateError('所选范围没有可请假的工作日');
  return slots;
}

class AnnualLeaveBalance {
  AnnualLeaveBalance(
    this.year,
    Iterable<AnnualLeaveRecord> records, {
    DateTime? now,
  }) : usedDays = records
           .where((r) => r.year == year)
           .fold<double>(0, (s, r) => s + r.days),
       currentYear = (now ?? DateTime.now()).year;
  final int year;
  final int currentYear;
  final double usedDays;
  double get allowance => year >= 2026 ? 5 : 0;
  double get remainingDays => max(0, allowance - usedDays);
  double get availableDays => year == currentYear ? remainingDays : 0;
  bool get expired => year < currentYear;
}

void validateAnnualLedger(
  List<AnnualLeaveRecord> annual,
  List<OvertimeRecord> overtime,
) {
  final ids = <String>{};
  final occupied = <String>{};
  final totals = <int, double>{};
  for (final record in annual) {
    final start = ledgerDate(record.startDate);
    final end = ledgerDate(record.endDate);
    if (!ids.add(record.id) ||
        record.id.isEmpty ||
        start.isAfter(end) ||
        start.year != end.year ||
        start.year < 2026 ||
        record.slots.isEmpty ||
        DateTime.tryParse(record.createdAt) == null) {
      throw const FormatException('年假记录日期、ID 或时段无效');
    }
    for (final slot in record.slots) {
      AnnualLeaveSlot.fromMap(slot.toMap());
      if (slot.date.compareTo(record.startDate) < 0 ||
          slot.date.compareTo(record.endDate) > 0 ||
          !occupied.add('${slot.date}/${slot.period}')) {
        throw const FormatException('年假记录包含越界或重复请假时段');
      }
      if (overtime.any(
        (r) =>
            r.isLeave &&
            r.otDate == slot.date &&
            slot.overlaps(r.startTime, r.endTime),
      )) {
        throw StateError('${slot.date} ${slot.label}与已有调休重叠');
      }
    }
    totals[record.year] = (totals[record.year] ?? 0) + record.days;
    if (totals[record.year]! > 5) throw StateError('${record.year} 年年假余额不足');
  }
}

void validateAnnualCalendar(
  List<AnnualLeaveRecord> records,
  LeaveCalendar calendar,
) {
  for (final record in records) {
    final same = record.startDate == record.endDate;
    final expected = buildAnnualLeaveSlots(
      start: ledgerDate(record.startDate),
      end: ledgerDate(record.endDate),
      startAfternoon:
          record.slots.any(
            (s) => s.date == record.startDate && s.period == 'pm',
          ) &&
          !record.slots.any(
            (s) => s.date == record.startDate && s.period == 'am',
          ),
      endMorning:
          record.slots.any(
            (s) => s.date == record.endDate && s.period == 'am',
          ) &&
          !record.slots.any(
            (s) => s.date == record.endDate && s.period == 'pm',
          ),
      singlePeriod: same && record.slots.length == 1
          ? record.slots.single.period
          : 'full',
      calendar: calendar.holidays,
      supportedYears: calendar.supportedYears,
    );
    if (jsonEncode(expected.map((s) => s.toMap()).toList()) !=
        jsonEncode(record.slots.map((s) => s.toMap()).toList())) {
      throw const FormatException('年假时段与工作日日历不一致');
    }
  }
}
