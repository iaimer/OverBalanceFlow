import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/business_rules.dart';
import 'common.dart';

class ReconcilePage extends StatefulWidget {
  const ReconcilePage({super.key, required this.controller});
  final AppController controller;

  @override
  State<ReconcilePage> createState() => _ReconcilePageState();
}

class _ReconcilePageState extends State<ReconcilePage> {
  DateTime date = DateTime.now();
  String start = '09:00';
  String end = '12:00';

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      Text(
        '可用余额 ${widget.controller.totalRemaining.toStringAsFixed(1)} 小时',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 6),
      const Text('确认前会列出每一笔 FIFO 扣减，账目不会在预览阶段改变。'),
      const SizedBox(height: 24),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('调休日期'),
        subtitle: Text(date.toIso8601String().substring(0, 10)),
        trailing: const Icon(Icons.calendar_today_outlined),
        onTap: () async {
          final value = await pickDate(context, date);
          if (value != null) setState(() => date = value);
        },
      ),
      Row(
        children: [
          Expanded(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('开始'),
              subtitle: Text(start),
              onTap: () async {
                final value = await pickTime(context, start);
                if (value != null) setState(() => start = value);
              },
            ),
          ),
          Expanded(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('结束'),
              subtitle: Text(end),
              onTap: () async {
                final value = await pickTime(context, end);
                if (value != null) setState(() => end = value);
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      FilledButton(
        onPressed: _preview,
        child: const Padding(
          padding: EdgeInsets.symmetric(vertical: 14),
          child: Text('预览 FIFO 核销'),
        ),
      ),
    ],
  );

  Future<void> _preview() async {
    try {
      final preview = widget.controller.previewLeave(start, end);
      if (preview.details.isEmpty) throw StateError('没有可用的加班余额');
      if (!mounted) return;
      final confirmed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (context) => _PreviewPage(
            preview: preview,
            date: date,
            start: start,
            end: end,
          ),
        ),
      );
      if (confirmed == true) {
        await widget.controller.reconcile(
          date: date,
          start: start,
          end: end,
          preview: preview,
        );
        if (mounted)
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('调休核销已事务入账')));
      }
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}

class _PreviewPage extends StatelessWidget {
  const _PreviewPage({
    required this.preview,
    required this.date,
    required this.start,
    required this.end,
  });
  final ReconciliationPreview preview;
  final DateTime date;
  final String start;
  final String end;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('确认核销')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          '${date.toIso8601String().substring(0, 10)}  $start–$end',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        ...preview.details.map(
          (item) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(item.info),
            trailing: Text('-${item.deduct.toStringAsFixed(1)}h'),
          ),
        ),
        if (preview.shortage > 0)
          Text(
            '余额不足，尚有 ${preview.shortage.toStringAsFixed(1)}h 未抵扣',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('确认并事务入账'),
          ),
        ),
      ],
    ),
  );
}
