import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../domain/annual_leave.dart';
import 'app_palette.dart';
import 'common.dart';

class AnnualLeaveSummary extends StatelessWidget {
  const AnnualLeaveSummary({super.key, required this.balance});
  final AnnualLeaveBalance balance;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppPalette.goldSoft,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Text('可用年假', style: TextStyle(color: AppPalette.ink)),
            const HelpTooltip(
              message: '每年提供 5 天年假，年底过期，不结转到下一年。',
              color: AppPalette.ink,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${balance.availableDays.toStringAsFixed(1)} 天',
          style: const TextStyle(
            fontSize: 28,
            height: 1.25,
            fontWeight: FontWeight.w800,
            color: AppPalette.ink,
          ),
        ),
      ],
    ),
  );
}

class AnnualLeaveTile extends StatelessWidget {
  const AnnualLeaveTile({
    super.key,
    required this.record,
    required this.controller,
    required this.onEdit,
  });
  final AnnualLeaveRecord record;
  final AppController controller;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(
      record.startDate == record.endDate
          ? record.startDate
          : '${record.startDate} 至 ${record.endDate}',
    ),
    subtitle: Text('年假 ${record.days.toStringAsFixed(1)} 天'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final action = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('年假记录', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  Text(
                    '${record.year} 年 · 已用 ${record.days.toStringAsFixed(1)} 天',
                  ),
                  if (record.reason.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('请假事由：${record.reason}'),
                    ),
                  ...record.slots.map(
                    (s) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('${s.date} ${s.label}'),
                      trailing: Text('${s.start}–${s.end}'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(context, 'edit'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('编辑记录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, 'delete'),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('删除记录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (action == 'edit') onEdit();
      if (action == 'delete' && context.mounted) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('确认删除年假'),
            content: Text('将返还到 ${record.year} 年额度，往年结余不会转入今年。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认删除'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        try {
          await controller.deleteAnnualLeave(record.id);
        } catch (error) {
          if (context.mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(error.toString())));
        }
      }
    },
  );
}
