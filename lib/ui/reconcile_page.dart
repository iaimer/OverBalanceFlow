import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../app_controller.dart';
import '../domain/annual_leave.dart';
import '../domain/business_rules.dart';
import '../domain/overtime_record.dart';
import 'common.dart';
import 'app_palette.dart';

class ReconcilePage extends StatefulWidget {
  const ReconcilePage({
    super.key,
    required this.controller,
    this.leaveRecord,
    this.annualRecord,
  }) : assert(leaveRecord == null || annualRecord == null);
  final AppController controller;
  final OvertimeRecord? leaveRecord;
  final AnnualLeaveRecord? annualRecord;
  @override
  State<ReconcilePage> createState() => _ReconcilePageState();
}

class _ReconcilePageState extends State<ReconcilePage> {
  DateTime date = DateTime.now();
  DateTime endDate = DateTime.now();
  String start = '08:30';
  String end = '11:30';
  bool annual = false;
  bool startAfternoon = false;
  bool endMorning = false;
  String singlePeriod = 'full';
  bool busy = false;
  bool needsRefresh = false;
  String requestId = const Uuid().v4();
  final reason = TextEditingController();
  bool get editing => widget.leaveRecord != null || widget.annualRecord != null;
  bool get sameDay => dateText(date) == dateText(endDate);

  @override
  void initState() {
    super.initState();
    if (widget.leaveRecord case final record?) {
      date = ledgerDate(record.otDate);
      start = record.startTime;
      end = record.endTime;
      reason.text = record.leaveReason ?? '';
    }
    if (widget.annualRecord case final record?) {
      annual = true;
      date = ledgerDate(record.startDate);
      endDate = ledgerDate(record.endDate);
      reason.text = record.reason;
      startAfternoon =
          record.slots.any(
            (s) => s.date == record.startDate && s.period == 'pm',
          ) &&
          !record.slots.any(
            (s) => s.date == record.startDate && s.period == 'am',
          );
      endMorning =
          record.slots.any(
            (s) => s.date == record.endDate && s.period == 'am',
          ) &&
          !record.slots.any(
            (s) => s.date == record.endDate && s.period == 'pm',
          );
      if (sameDay && record.slots.length == 1)
        singlePeriod = record.slots.single.period;
    }
  }

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final balance = widget.controller.annualBalance(date.year);
    final oldDays = widget.annualRecord?.year == date.year
        ? widget.annualRecord!.days
        : 0;
    final balanceTitle = annual
        ? '${date.year} 年年假${balance.expired ? '结余' : '余额'}'
        : widget.leaveRecord != null
        ? '可重新分配调休额度'
        : '可用调休余额';
    final balanceHelp = annual
        ? '每年提供 5 天年假，年底过期不结转；历史补录按请假日期所属年份扣除。'
        : '确认前会列出 FIFO 扣减，余额不足时无法登记。';
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        if (!editing) ...[
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('调休')),
              ButtonSegment(value: true, label: Text('年假')),
            ],
            selected: {annual},
            onSelectionChanged: busy
                ? null
                : (v) => setState(() => annual = v.single),
          ),
          const SizedBox(height: 20),
        ],
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppPalette.tealSoft,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      balanceTitle,
                      style: const TextStyle(color: AppPalette.inkMuted),
                    ),
                  ),
                  HelpTooltip(message: balanceHelp, color: AppPalette.tealDeep),
                ],
              ),
              Text(
                annual
                    ? '${(balance.remainingDays + oldDays).toStringAsFixed(1)} 天'
                    : '${(widget.controller.totalRemaining - (widget.leaveRecord?.duration ?? 0)).toStringAsFixed(1)} 小时',
                style: const TextStyle(
                  color: AppPalette.tealDeep,
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const SizedBox(height: 4),
        if (annual) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('年假日期范围'),
                HelpTooltip(message: '只计算工作日，每个上午或下午固定扣 0.5 天。'),
              ],
            ),
            subtitle: Text('${dateText(date)} 至 ${dateText(endDate)}'),
            trailing: const Icon(Icons.date_range_outlined),
            onTap: busy ? null : _pickRange,
          ),
          if (sameDay)
            DropdownButtonFormField<String>(
              initialValue: singlePeriod,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '请假时段',
                suffixIcon: HelpTooltip(
                  message: '上午按 8:30–11:30 判断，下午按 12:00–17:00 判断。',
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'full', child: Text('整天')),
                DropdownMenuItem(value: 'am', child: Text('上午半天')),
                DropdownMenuItem(value: 'pm', child: Text('下午半天')),
              ],
              onChanged: busy ? null : (v) => setState(() => singlePeriod = v!),
            )
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('首日只请下午'),
              value: startAfternoon,
              onChanged: busy
                  ? null
                  : (v) => setState(() => startAfternoon = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('末日只请上午'),
              value: endMorning,
              onChanged: busy ? null : (v) => setState(() => endMorning = v),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '已更新完整日历：${(widget.controller.annualCalendar.supportedYears.toList()..sort()).join('、')} 年',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ] else ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('调休日期'),
            subtitle: Text(dateText(date)),
            trailing: const Icon(Icons.calendar_today_outlined),
            onTap: busy
                ? null
                : () async {
                    final value = await pickDate(context, date);
                    if (value != null && mounted) setState(() => date = value);
                  },
          ),
          Row(
            children: [
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开始'),
                  subtitle: Text(start),
                  onTap: busy ? null : () => _pickClock(true),
                ),
              ),
              Expanded(
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('结束'),
                  subtitle: Text(end),
                  onTap: busy ? null : () => _pickClock(false),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: reason,
          enabled: !busy,
          maxLines: 2,
          decoration: const InputDecoration(labelText: '请假事由（选填）'),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: busy
              ? null
              : needsRefresh
              ? _refreshSaved
              : _preview,
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.tealDeep,
            foregroundColor: AppPalette.surface,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              busy
                  ? '正在处理…'
                  : needsRefresh
                  ? '刷新已保存的记录'
                  : annual
                  ? '预览年假扣减'
                  : '预览 FIFO 核销',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _pickRange() async {
    final value = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2026),
      lastDate: DateTime(2100, 12, 31),
      initialDateRange: DateTimeRange(start: date, end: endDate),
    );
    if (value != null && mounted)
      setState(() {
        date = value.start;
        endDate = value.end;
      });
  }

  Future<void> _pickClock(bool isStart) async {
    final value = await pickTime(context, isStart ? start : end);
    if (value != null && mounted)
      setState(() {
        if (isStart) {
          start = value;
        } else {
          end = value;
        }
      });
  }

  Future<void> _refreshSaved() async {
    setState(() => busy = true);
    try {
      await widget.controller.syncFromCloud();
      if (!mounted) return;
      needsRefresh = false;
      requestId = const Uuid().v4();
      if (editing) Navigator.pop(context, true);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _preview() async {
    setState(() => busy = true);
    try {
      final annualPreview = annual
          ? widget.controller.previewAnnualLeave(
              startDate: date,
              endDate: endDate,
              startAfternoon: startAfternoon,
              endMorning: endMorning,
              singlePeriod: singlePeriod,
              reason: reason.text,
              editingId: widget.annualRecord?.id,
            )
          : null;
      final fifo = annual
          ? null
          : widget.controller.previewLeave(
              start,
              end,
              date: date,
              editingId: widget.leaveRecord?.id,
            );
      final confirmed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => _PreviewPage(
            annual: annualPreview,
            fifo: fifo,
            date: date,
            start: start,
            end: end,
            reason: reason.text.trim(),
          ),
        ),
      );
      if (confirmed != true) return;
      if (annualPreview != null) {
        await widget.controller.saveAnnualLeave(
          annualPreview,
          editing: editing,
        );
      } else {
        await widget.controller.reconcile(
          date: date,
          start: start,
          end: end,
          preview: fifo!,
          reason: reason.text,
          editingId: widget.leaveRecord?.id,
          newRecordId: requestId,
        );
      }
      if (!mounted) return;
      requestId = const Uuid().v4();
      if (editing) {
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(annual ? '年假已入账' : '调休已入账')));
      }
    } catch (error) {
      if (error is CloudRefreshException) needsRefresh = true;
      if (mounted)
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              error is CloudRefreshException ? '已写入云端，需刷新' : '暂时无法保存',
            ),
            content: Text(error.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class _PreviewPage extends StatelessWidget {
  const _PreviewPage({
    this.annual,
    this.fifo,
    required this.date,
    required this.start,
    required this.end,
    required this.reason,
  });
  final AnnualLeaveRecord? annual;
  final ReconciliationPreview? fifo;
  final DateTime date;
  final String start;
  final String end;
  final String reason;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(annual == null ? '确认调休核销' : '确认年假扣减')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          annual == null
              ? '${dateText(date)} $start–$end'
              : '${annual!.startDate} 至 ${annual!.endDate}',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (reason.isNotEmpty) Text('事由：$reason'),
        if (annual != null) ...[
          Text('扣除 ${annual!.days.toStringAsFixed(1)} 天，所属年度 ${annual!.year}'),
          ...annual!.slots.map(
            (s) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${s.date} ${s.label}'),
              subtitle: Text('${s.start}–${s.end}'),
              trailing: const Text('−0.5 天'),
            ),
          ),
        ] else
          ...fifo!.details.map(
            (d) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(d.info),
              trailing: Text('−${d.deduct.toStringAsFixed(1)}h'),
            ),
          ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.tealDeep,
            foregroundColor: AppPalette.surface,
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('确认并保存'),
          ),
        ),
      ],
    ),
  );
}
