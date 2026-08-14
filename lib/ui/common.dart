import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app_controller.dart';
import '../domain/overtime_record.dart';

Future<DateTime?> pickDate(BuildContext context, DateTime current) =>
    showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );

Future<String?> pickTime(BuildContext context, String current) async {
  final parts = current.split(':').map(int.parse).toList();
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: parts[0], minute: parts[1]),
  );
  if (time == null) return null;
  return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class RecordTile extends StatelessWidget {
  const RecordTile({
    super.key,
    required this.record,
    required this.controller,
    this.compact = false,
  });
  final OvertimeRecord record;
  final AppController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: compact ? EdgeInsets.zero : null,
    title: Text('${record.otDate}  ${record.startTime}–${record.endTime}'),
    subtitle: Text(
      record.isLeave
          ? '调休 ${(-record.duration).toStringAsFixed(1)}h'
          : '${record.status} · 余额 ${record.remainingHours.toStringAsFixed(1)}h',
    ),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => showRecordDetails(context, record, controller),
  );
}

Future<void> showRecordDetails(
  BuildContext context,
  OvertimeRecord record,
  AppController controller,
) async {
  final leaveDeductions = record.isLeave
      ? _leaveDeductions(record, controller.records)
      : const <_LeaveDeduction>[];
  final path = record.photoPath == null
      ? null
      : p.join(
          controller.database.rootDirectory.path,
          record.photoPath!.startsWith('photos/') ? '' : 'photos',
          record.photoPath,
        );
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                record.isLeave ? '调休记录' : '加班记录',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                record.isLeave
                    ? '${record.otDate} 调休'
                    : '${record.otDate}  ${record.startTime}–${record.endTime}',
              ),
              Text(
                record.isLeave
                    ? '已核销 ${(-record.duration).toStringAsFixed(1)} 小时'
                    : '原始 ${record.duration.toStringAsFixed(1)} 小时，余额 ${record.remainingHours.toStringAsFixed(1)} 小时',
              ),
              if (record.isLeave && leaveDeductions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('使用的加班记录', style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                ...leaveDeductions.map(
                  (deduction) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      [
                        deduction.date,
                        deduction.timeRange,
                      ].where((part) => part.isNotEmpty).join('  '),
                    ),
                    trailing: Text('-${deduction.hours.toStringAsFixed(1)} 小时'),
                  ),
                ),
              ],
              if (!record.isLeave && record.memo.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(record.memo),
              ],
              if (path != null && File(path).existsSync()) ...[
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(path), height: 180, fit: BoxFit.cover),
                ),
              ],
              const SizedBox(height: 20),
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除记录'),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: sheetContext,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('再次确认删除'),
                      content: Text(
                        record.isLeave
                            ? '删除调休后，关联加班余额将在同一事务中返还。'
                            : '删除后无法从本地撤销，请先确认已有备份。',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: const Text('确认删除'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed != true || !sheetContext.mounted) return;
                  final cleanupDeferred = await controller.delete(record.id);
                  if (!sheetContext.mounted) return;
                  Navigator.pop(sheetContext);
                  if (cleanupDeferred && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('记录已删除；照片清理将稍后重试。')),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

List<_LeaveDeduction> _leaveDeductions(
  OvertimeRecord leave,
  List<OvertimeRecord> records,
) {
  try {
    final recordsById = {for (final record in records) record.id: record};
    return ReconciliationDetail.decode(leave.memo).map((detail) {
      final overtime = recordsById[detail.id];
      return _LeaveDeduction(
        date: overtime?.otDate ?? '已关联的加班记录',
        timeRange: overtime == null
            ? ''
            : '${overtime.startTime}–${overtime.endTime}',
        hours: detail.deduct,
      );
    }).toList();
  } catch (_) {
    return const [];
  }
}

class _LeaveDeduction {
  const _LeaveDeduction({
    required this.date,
    required this.timeRange,
    required this.hours,
  });

  final String date;
  final String timeRange;
  final double hours;
}
