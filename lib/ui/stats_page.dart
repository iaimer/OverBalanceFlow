import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/overtime_record.dart';
import 'common.dart';
import 'app_palette.dart';

enum RecordFilter { all, overtime, leave }

class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.controller});
  final AppController controller;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  RecordFilter filter = RecordFilter.all;

  @override
  Widget build(BuildContext context) {
    List<OvertimeRecord> filtered = widget.controller.records;
    if (filter == RecordFilter.overtime)
      filtered = filtered.where((record) => !record.isLeave).toList();
    if (filter == RecordFilter.leave)
      filtered = filtered.where((record) => record.isLeave).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          decoration: BoxDecoration(
            color: AppPalette.tealDeep,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '可用调休余额',
                style: TextStyle(color: AppPalette.tealSoft),
              ),
              Text(
                '${widget.controller.totalRemaining.toStringAsFixed(1)} 小时',
                style: const TextStyle(
                  color: AppPalette.surface,
                  fontSize: 34,
                  height: 1.25,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '按最早加班记录优先核销',
                style: TextStyle(color: AppPalette.tealSoft),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Metric(
                label: '累计加班',
                value: widget.controller.totalOvertime,
                color: AppPalette.coral,
                background: AppPalette.coralSoft,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Metric(
                label: '累计调休',
                value: widget.controller.totalLeave,
                color: AppPalette.tealDeep,
                background: AppPalette.tealSoft,
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('全部记录', style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<RecordFilter>(
              segments: const [
                ButtonSegment(value: RecordFilter.all, label: Text('全部')),
                ButtonSegment(value: RecordFilter.overtime, label: Text('加班')),
                ButtonSegment(value: RecordFilter.leave, label: Text('调休')),
              ],
              selected: {filter},
              onSelectionChanged: (value) =>
                  setState(() => filter = value.single),
              showSelectedIcon: false,
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('没有符合条件的记录')),
          ),
        ...filtered.map(
          (record) => RecordTile(record: record, controller: widget.controller),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
    required this.background,
  });

  final String label;
  final double value;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppPalette.inkMuted)),
        const SizedBox(height: 5),
        Text(
          '${value.toStringAsFixed(1)}h',
          style: TextStyle(
            color: color,
            fontSize: 22,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}
