import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/overtime_record.dart';
import 'common.dart';

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
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('可用调休'),
                    Text(
                      '${widget.controller.totalRemaining.toStringAsFixed(1)}h',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ],
                ),
              ),
              Text(
                '累计加班 ${widget.controller.totalOvertime.toStringAsFixed(1)}h\n已用调休 ${widget.controller.totalLeave.toStringAsFixed(1)}h',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
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
