import 'overtime_record.dart';

class LedgerValidator {
  static void validate(List<OvertimeRecord> records) {
    final byId = {for (final record in records) record.id: record};
    if (byId.length != records.length) {
      throw const FormatException('账本包含重复 UUID');
    }
    final deducted = <String, double>{};
    for (final record in records) {
      if ((record.totalHours - record.duration).abs() > 0.001) {
        throw FormatException('记录 ${record.id} 的 total_hours 与 duration 不一致');
      }
      if (record.isLeave) {
        if (record.duration >= 0 || record.remainingHours != 0) {
          throw FormatException('调休记录 ${record.id} 的时长或余额符号无效');
        }
      } else if (record.duration <= 0 ||
          record.remainingHours < 0 ||
          record.remainingHours > record.duration) {
        throw FormatException('加班记录 ${record.id} 的时长或余额无效');
      }
    }
    for (final leave in records.where((record) => record.isLeave)) {
      List<ReconciliationDetail> details;
      try {
        details = ReconciliationDetail.decode(leave.memo);
      } catch (_) {
        throw FormatException('调休记录 ${leave.id} 的核销明细无法解析');
      }
      final detailTotal = details.fold<double>(0, (sum, item) {
        if (item.deduct <= 0) {
          throw FormatException('调休记录 ${leave.id} 包含非正数扣减');
        }
        final target = byId[item.id];
        if (target == null || target.isLeave) {
          throw FormatException('调休记录 ${leave.id} 引用了不存在的加班 ${item.id}');
        }
        deducted[item.id] = (deducted[item.id] ?? 0) + item.deduct;
        return sum + item.deduct;
      });
      if ((detailTotal + leave.duration).abs() > 0.001) {
        throw FormatException('调休记录 ${leave.id} 的存根时长与明细不一致');
      }
    }
    for (final overtime in records.where((record) => !record.isLeave)) {
      final used = deducted[overtime.id] ?? 0;
      final expected = overtime.duration - used;
      if (expected < -0.001 ||
          (expected - overtime.remainingHours).abs() > 0.001) {
        throw FormatException('加班记录 ${overtime.id} 的余额与核销历史不一致');
      }
      final expectedStatus = overtime.remainingHours <= 0
          ? '已结清'
          : used > 0
          ? '部分核销'
          : '待核销';
      if (overtime.status != expectedStatus) {
        throw FormatException('加班记录 ${overtime.id} 的状态与余额不一致');
      }
    }
  }
}
