import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/business_rules.dart';
import '../domain/holiday_calendar.dart';
import '../domain/overtime_record.dart';
import 'app_palette.dart';
import 'common.dart';

class OvertimeEditorPage extends StatefulWidget {
  const OvertimeEditorPage({
    super.key,
    required this.controller,
    required this.record,
  });

  final AppController controller;
  final OvertimeRecord record;

  @override
  State<OvertimeEditorPage> createState() => _OvertimeEditorPageState();
}

class _OvertimeEditorPageState extends State<OvertimeEditorPage> {
  late DateTime date;
  late String start;
  late String end;
  late final TextEditingController memo;
  late final OvertimeRecord _snapshot;
  bool saving = false;
  bool _remoteChanged = false;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.record;
    date = DateTime.tryParse(widget.record.otDate) ?? DateTime.now();
    start = widget.record.startTime;
    end = widget.record.endTime;
    memo = TextEditingController(text: widget.record.memo);
    final current = _currentRecord;
    _remoteChanged =
        current == null || !_sameEditableFields(current, _snapshot);
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    memo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('编辑加班记录')),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final dateText = _dateText(date);
    final estimated = widget.controller.duration(start, end, date);
    final conflicts = findOverlappingOvertime(
      widget.controller.records,
      date: dateText,
      startTime: start,
      endTime: end,
      excludingId: widget.record.id,
    );
    final currentRecord = widget.controller.records
        .where((record) => record.id == widget.record.id)
        .firstOrNull;
    final balanceRecord = currentRecord ?? widget.record;
    final consumed = balanceRecord.duration - balanceRecord.remainingHours;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                consumed > 0
                    ? '已保留 ${consumed.toStringAsFixed(1)} 小时的历史核销'
                    : '编辑记录',
                style: const TextStyle(color: AppPalette.inkMuted),
              ),
            ),
            HelpTooltip(
              message: consumed > 0
                  ? '新的时长不能低于已保留的历史核销量。'
                  : '可以修正日期、时间和备注，原打卡照片会保留。',
            ),
          ],
        ),
        if (_remoteChanged) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.sync_problem_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 10),
                const Expanded(child: Text('这条记录已在其他位置更新，请返回后重新打开编辑。')),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        _Picker(
          label: '加班日期',
          value: dateText,
          onTap: () async {
            final value = await pickDate(context, date);
            if (value != null && mounted) setState(() => date = value);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppPalette.goldSoft,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                child: Text(
                  widget.controller.dayType(date).label,
                  style: const TextStyle(
                    color: AppPalette.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Picker(
                label: '开始时间',
                value: start,
                onTap: () async {
                  final value = await pickTime(context, start);
                  if (value != null && mounted) setState(() => start = value);
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Picker(
                label: '结束时间',
                value: end,
                onTap: () async {
                  final value = await pickTime(context, end);
                  if (value != null && mounted) setState(() => end = value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: estimated > 0 ? AppPalette.coralSoft : AppPalette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: estimated > 0 ? AppPalette.coral : AppPalette.outline,
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.schedule_outlined,
                color: estimated > 0
                    ? AppPalette.coralDeep
                    : AppPalette.inkMuted,
              ),
              const SizedBox(width: 10),
              Text(
                estimated > 0
                    ? '预计计入 ${estimated.toStringAsFixed(1)} 小时'
                    : '当前时间不满足计入规则',
                style: TextStyle(
                  color: estimated > 0
                      ? AppPalette.coralDeep
                      : AppPalette.inkMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (conflicts.isNotEmpty) ...[
          const SizedBox(height: 12),
          OvertimeConflictNotice(conflicts: conflicts),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: memo,
          maxLines: 2,
          decoration: const InputDecoration(labelText: '备注（选填）'),
        ),
        if (balanceRecord.photoPath != null) ...[
          const SizedBox(height: 12),
          const Row(
            children: [
              Icon(Icons.photo_outlined, size: 18, color: AppPalette.tealDeep),
              SizedBox(width: 6),
              Text(
                '原打卡照片会保留',
                style: TextStyle(
                  color: AppPalette.tealDeep,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.coralDeep,
            foregroundColor: AppPalette.surface,
          ),
          onPressed: saving || conflicts.isNotEmpty || _remoteChanged
              ? null
              : _save,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(saving ? '正在保存…' : '保存修改'),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (_remoteChanged) return;
    setState(() => saving = true);
    try {
      await widget.controller.updateOvertime(
        id: widget.record.id,
        date: date,
        start: start,
        end: end,
        memo: memo.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  static String _dateText(DateTime value) =>
      value.toIso8601String().substring(0, 10);

  OvertimeRecord? get _currentRecord => widget.controller.records
      .where((record) => record.id == widget.record.id)
      .firstOrNull;

  void _onControllerChanged() {
    if (_remoteChanged) return;
    final current = _currentRecord;
    final changed = current == null || !_sameEditableFields(current, _snapshot);
    if (!changed) return;
    if (mounted) {
      setState(() => _remoteChanged = true);
    } else {
      _remoteChanged = true;
    }
  }

  static bool _sameEditableFields(
    OvertimeRecord first,
    OvertimeRecord second,
  ) =>
      first.otDate == second.otDate &&
      first.startTime == second.startTime &&
      first.endTime == second.endTime &&
      first.memo == second.memo &&
      first.photoPath == second.photoPath;
}

class _Picker extends StatelessWidget {
  const _Picker({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(value), const Icon(Icons.expand_more)],
      ),
    ),
  );
}
