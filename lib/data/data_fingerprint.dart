import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/overtime_record.dart';

class DataFingerprint {
  const DataFingerprint({
    required this.recordCount,
    required this.recordsSha256,
    required this.uuidSha256,
    required this.statusCounts,
    required this.totalDuration,
    required this.totalRemaining,
    required this.photoCount,
  });

  final int recordCount;
  final String recordsSha256;
  final String uuidSha256;
  final Map<String, int> statusCounts;
  final double totalDuration;
  final double totalRemaining;
  final int photoCount;

  factory DataFingerprint.fromRecords(List<OvertimeRecord> records) {
    final ids = records.map((record) => record.id).toList()..sort();
    final canonicalRecords =
        records.map((record) {
            final map = Map<String, Object?>.from(record.toMap());
            map['photo_path'] = record.photoPath == null ? null : '<photo>';
            return map;
          }).toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final counts = <String, int>{};
    for (final record in records) {
      counts[record.status] = (counts[record.status] ?? 0) + 1;
    }
    final overtime = records.where((record) => !record.isLeave);
    return DataFingerprint(
      recordCount: records.length,
      recordsSha256: sha256
          .convert(utf8.encode(jsonEncode(canonicalRecords)))
          .toString(),
      uuidSha256: sha256.convert(utf8.encode(ids.join('\n'))).toString(),
      statusCounts: counts,
      totalDuration: _round(
        overtime.fold(0, (sum, record) => sum + record.duration),
      ),
      totalRemaining: _round(
        overtime.fold(0, (sum, record) => sum + record.remainingHours),
      ),
      photoCount: records.where((record) => record.photoPath != null).length,
    );
  }

  Map<String, Object> toMap() => {
    'record_count': recordCount,
    'records_sha256': recordsSha256,
    'uuid_sha256': uuidSha256,
    'status_counts': statusCounts,
    'total_duration': totalDuration,
    'total_remaining': totalRemaining,
    'photo_count': photoCount,
  };
}

double _round(double value) => (value * 1000000).round() / 1000000;
