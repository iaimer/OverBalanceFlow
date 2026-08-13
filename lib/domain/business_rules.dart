import 'dart:math';

import 'overtime_record.dart';

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
