import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/overtime_record.dart';
import '../domain/annual_leave.dart';
import 'reconcile_page.dart';
import 'annual_leave_widgets.dart';
import 'common.dart';
import 'app_palette.dart';
import 'overtime_editor_page.dart';

enum RecordFilter { all, overtime, leave, annual }

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
    if (filter == RecordFilter.annual) filtered = [];
    final entries =
        <({String date, String id, Widget tile})>[
          for (final record in filtered)
            (
              date: record.otDate,
              id: record.id,
              tile: RecordTile(
                record: record,
                controller: widget.controller,
                onEdit: () => _openEditor(record),
              ),
            ),
          if (filter == RecordFilter.all || filter == RecordFilter.annual)
            for (final record in widget.controller.annualRecords)
              (
                date: record.startDate,
                id: record.id,
                tile: AnnualLeaveTile(
                  record: record,
                  controller: widget.controller,
                  onEdit: () => _openAnnualEditor(record),
                ),
              ),
        ]..sort((a, b) {
          final order = b.date.compareTo(a.date);
          return order != 0 ? order : b.id.compareTo(a.id);
        });
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  key: const Key('comp-balance-card'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppPalette.tealDeep,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            '可用调休',
                            style: TextStyle(color: AppPalette.tealSoft),
                          ),
                          HelpTooltip(
                            message: '调休按 FIFO 核销，优先使用最早加班记录的可用余额。',
                            color: AppPalette.tealSoft,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${widget.controller.totalRemaining.toStringAsFixed(1)} 小时',
                        style: const TextStyle(
                          color: AppPalette.surface,
                          fontSize: 28,
                          height: 1.25,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnnualLeaveSummary(
                  key: const Key('annual-balance-card'),
                  balance: widget.controller.annualBalance(DateTime.now().year),
                ),
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
        Text('全部记录', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in const {
              RecordFilter.all: '全部',
              RecordFilter.overtime: '加班',
              RecordFilter.leave: '调休',
              RecordFilter.annual: '年假',
            }.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: filter == entry.key,
                onSelected: (_) => setState(() => filter = entry.key),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('没有符合条件的记录')),
          ),
        ...entries.map((entry) => entry.tile),
      ],
    );
  }

  Future<void> _openEditor(OvertimeRecord record) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => record.isLeave
            ? Scaffold(
                appBar: AppBar(title: const Text('编辑调休')),
                body: ReconcilePage(
                  controller: widget.controller,
                  leaveRecord: record,
                ),
              )
            : OvertimeEditorPage(controller: widget.controller, record: record),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('记录已更新')));
    }
  }

  Future<void> _openAnnualEditor(AnnualLeaveRecord record) async {
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('编辑年假')),
          body: ReconcilePage(
            controller: widget.controller,
            annualRecord: record,
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
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
