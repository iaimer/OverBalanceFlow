import 'dart:convert';

const allowedStatuses = <String>{'待核销', '部分核销', '已结清', '已调休'};

class OvertimeRecord {
  const OvertimeRecord({
    required this.id,
    required this.otDate,
    required this.startTime,
    required this.endTime,
    required this.duration,
    required this.totalHours,
    required this.remainingHours,
    required this.status,
    required this.memo,
    required this.createdAt,
    this.photoPath,
  });

  final String id;
  final String otDate;
  final String startTime;
  final String endTime;
  final double duration;
  final double totalHours;
  final double remainingHours;
  final String status;
  final String memo;
  final String createdAt;
  final String? photoPath;

  bool get isLeave => status == '已调休';

  factory OvertimeRecord.fromMap(Map<String, dynamic> map) {
    String requiredText(String key) {
      final value = map[key];
      if (value == null || value.toString().isEmpty) {
        throw FormatException('记录缺少必填字段：$key');
      }
      return value.toString();
    }

    double requiredNumber(String key) {
      final value = map[key];
      if (value is! num) throw FormatException('记录数值字段无效：$key');
      return value.toDouble();
    }

    final status = requiredText('status');
    if (!allowedStatuses.contains(status)) {
      throw FormatException('未知状态：$status');
    }
    return OvertimeRecord(
      id: requiredText('id'),
      otDate: requiredText('ot_date'),
      startTime: _shortTime(requiredText('start_time')),
      endTime: _shortTime(requiredText('end_time')),
      duration: requiredNumber('duration'),
      totalHours: requiredNumber('total_hours'),
      remainingHours: requiredNumber('remaining_hours'),
      status: status,
      memo: map['memo']?.toString() ?? '',
      createdAt: requiredText('created_at'),
      photoPath: _nullable(map['photo_path']),
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'ot_date': otDate,
    'start_time': startTime,
    'end_time': endTime,
    'duration': duration,
    'total_hours': totalHours,
    'remaining_hours': remainingHours,
    'status': status,
    'memo': memo,
    'created_at': createdAt,
    'photo_path': photoPath,
  };

  OvertimeRecord copyWith({
    double? remainingHours,
    String? status,
    String? photoPath,
  }) => OvertimeRecord(
    id: id,
    otDate: otDate,
    startTime: startTime,
    endTime: endTime,
    duration: duration,
    totalHours: totalHours,
    remainingHours: remainingHours ?? this.remainingHours,
    status: status ?? this.status,
    memo: memo,
    createdAt: createdAt,
    photoPath: photoPath ?? this.photoPath,
  );

  static String _shortTime(String text) {
    if (!RegExp(r'^\d{2}:\d{2}(:\d{2}(\.\d+)?)?$').hasMatch(text)) {
      throw FormatException('时间字段无效：$text');
    }
    return text.substring(0, 5);
  }

  static String? _nullable(Object? value) {
    final text = value?.toString();
    return text == null || text.isEmpty ? null : text;
  }
}

class ReconciliationDetail {
  const ReconciliationDetail({
    required this.id,
    required this.deduct,
    required this.info,
  });
  final String id;
  final double deduct;
  final String info;

  Map<String, Object> toMap() => {'id': id, 'deduct': deduct, 'info': info};

  factory ReconciliationDetail.fromMap(Map<String, dynamic> map) =>
      ReconciliationDetail(
        id: map['id'].toString(),
        deduct: (map['deduct'] as num).toDouble(),
        info: map['info']?.toString() ?? '',
      );

  static List<ReconciliationDetail> decode(String memo) {
    final value = jsonDecode(memo) as List<dynamic>;
    return value
        .map(
          (item) => ReconciliationDetail.fromMap(item as Map<String, dynamic>),
        )
        .toList();
  }
}
