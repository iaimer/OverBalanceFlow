import 'dart:math';

import 'overtime_record.dart';

/// 返回 `HH:mm` 在一天中的分钟数。
///
/// 业务规则把 `23:59` 当作当天结束（24:00）处理，因此重叠判断也沿用
/// 相同的约定。输入不合法时返回 null，由调用方继续走原有的时长校验。
int? clockMinutes(String value) {
  final match = RegExp(r'^(\d{2}):(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match.group(1)!);
  final minute = int.parse(match.group(2)!);
  if (hour > 23 || minute > 59) return null;
  if (value == '23:59') return 24 * 60;
  return hour * 60 + minute;
}

/// 判断两个同日时间区间是否存在实际交集。
///
/// 区间采用左闭右开语义，前一条记录结束时间等于后一条开始时间时不重叠。
bool overtimeIntervalsOverlap({
  required String firstStart,
  required String firstEnd,
  required String secondStart,
  required String secondEnd,
}) {
  final firstStartMinutes = clockMinutes(firstStart);
  final firstEndMinutes = clockMinutes(firstEnd);
  final secondStartMinutes = clockMinutes(secondStart);
  final secondEndMinutes = clockMinutes(secondEnd);
  if (firstStartMinutes == null ||
      firstEndMinutes == null ||
      secondStartMinutes == null ||
      secondEndMinutes == null ||
      firstStartMinutes >= firstEndMinutes ||
      secondStartMinutes >= secondEndMinutes) {
    return false;
  }
  return firstStartMinutes < secondEndMinutes &&
      secondStartMinutes < firstEndMinutes;
}

/// 查找同一天、与目标时间段实际交集的加班记录。
List<OvertimeRecord> findOverlappingOvertime(
  List<OvertimeRecord> records, {
  required String date,
  required String startTime,
  required String endTime,
  String? excludingId,
}) {
  return records
      .where(
        (record) =>
            !record.isLeave &&
            record.otDate == date &&
            record.id != excludingId &&
            overtimeIntervalsOverlap(
              firstStart: startTime,
              firstEnd: endTime,
              secondStart: record.startTime,
              secondEnd: record.endTime,
            ),
      )
      .toList();
}

class OvertimeOverlapException implements Exception {
  const OvertimeOverlapException(this.conflicts);

  final List<OvertimeRecord> conflicts;

  @override
  String toString() {
    final ranges = conflicts
        .map(
          (record) => '${record.otDate} ${record.startTime}–${record.endTime}',
        )
        .join('、');
    return '时间段与已有加班记录重叠：$ranges';
  }
}

class OvertimeDurationException implements Exception {
  const OvertimeDurationException(this.consumedHours);

  final double consumedHours;

  @override
  String toString() => '新的时长不能少于已核销的 ${consumedHours.toStringAsFixed(1)} 小时';
}

class OvertimeEditBalance {
  const OvertimeEditBalance({
    required this.consumedHours,
    required this.remainingHours,
    required this.status,
  });

  final double consumedHours;
  final double remainingHours;
  final String status;
}

/// 根据历史核销量计算编辑后的余额和状态。
///
/// 已核销小时数必须继续被新时长覆盖，避免编辑操作制造无法解释的核销历史。
OvertimeEditBalance calculateOvertimeEditBalance(
  OvertimeRecord record,
  double newDuration,
) {
  final consumed = record.duration - record.remainingHours;
  if (consumed < 0 || newDuration + 0.001 < consumed) {
    throw OvertimeDurationException(consumed);
  }
  final double remaining = max(0.0, newDuration - consumed);
  return OvertimeEditBalance(
    consumedHours: consumed,
    remainingHours: remaining,
    status: remaining <= 0
        ? '已结清'
        : consumed > 0
        ? '部分核销'
        : '待核销',
  );
}

double parseDuration(
  String start,
  String end, {
  bool isLeave = false,
  bool isDayOff = false,
}) {
  double parse(String value) {
    if (value == '23:59') return 24;
    final parts = value.split(':');
    if (parts.length != 2) return 0;
    return int.parse(parts[0]) + int.parse(parts[1]) / 60;
  }

  final startValue = parse(start);
  final endValue = parse(end);
  if (startValue >= endValue) return 0;
  final skipWorkdayRules = isLeave || isDayOff;
  if (!skipWorkdayRules && endValue < 18) return 0;
  final effectiveStart = skipWorkdayRules ? startValue : max(startValue, 17);
  var raw = endValue - effectiveStart;
  raw -= max(0, min(endValue, 12) - max(effectiveStart, 11.5));
  if (raw <= 0) return 0;
  return max(0.5, (raw / 0.5).floor() * 0.5);
}

class ReconciliationPreview {
  const ReconciliationPreview({
    required this.details,
    required this.requestedHours,
    required this.deductedHours,
  });
  final List<ReconciliationDetail> details;
  final double requestedHours;
  final double deductedHours;
  double get shortage => max(0, requestedHours - deductedHours);
}

ReconciliationPreview previewFifo(
  List<OvertimeRecord> records,
  double requestedHours,
) {
  final inventory =
      records
          .where((record) => !record.isLeave && record.remainingHours > 0)
          .toList()
        ..sort((a, b) {
          var result = a.otDate.compareTo(b.otDate);
          if (result == 0) result = a.createdAt.compareTo(b.createdAt);
          if (result == 0) result = a.id.compareTo(b.id);
          return result;
        });
  var pending = requestedHours;
  final details = <ReconciliationDetail>[];
  for (final record in inventory) {
    if (pending <= 0) break;
    final deduct = min(record.remainingHours, pending);
    details.add(
      ReconciliationDetail(
        id: record.id,
        deduct: _round(deduct),
        info:
            '${record.otDate}(${record.startTime}-${record.endTime}) '
            '余额:${record.remainingHours.toStringAsFixed(1)}h',
      ),
    );
    pending -= deduct;
  }
  final total = details.fold<double>(0, (sum, item) => sum + item.deduct);
  return ReconciliationPreview(
    details: details,
    requestedHours: requestedHours,
    deductedHours: _round(total),
  );
}

double _round(double value) => (value * 100).round() / 100;
