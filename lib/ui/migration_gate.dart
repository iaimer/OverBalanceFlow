import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

import '../app_controller.dart';

class MigrationGate extends StatelessWidget {
  const MigrationGate({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
            Icon(
              Icons.shield_outlined,
              size: 52,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              '先安全迁移历史记录',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              '应用会以只读方式复制 Supabase 中的全部记录和照片，先写入暂存区并逐项校验。任何失败都不会修改云端，也不会留下不完整的本地账本。',
            ),
            if (controller.migrationError != null) ...[
              const SizedBox(height: 20),
              Text(
                controller.migrationError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: controller.loading ? null : controller.migrate,
                icon: const Icon(Icons.download_done_outlined),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('开始只读迁移并校验'),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (kDebugMode) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: controller.loading
                      ? null
                      : () => _loadSample(context),
                  icon: const Icon(Icons.science_outlined),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Text('载入模拟数据（仅调试版）'),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: controller.loading ? null : () => _restore(context),
                icon: const Icon(Icons.settings_backup_restore),
                label: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: Text('从已验证 ZIP 恢复'),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text('请保持旧 Web 数据和 Supabase 不变，直到迁移报告、重启和备份恢复均验证通过。'),
          ],
        ),
      ),
    ),
  );

  Future<void> _restore(BuildContext context) async {
    const group = XTypeGroup(
      label: '偷闲半日 ZIP 备份',
      extensions: ['zip'],
    );
    final selected = await openFile(acceptedTypeGroups: [group]);
    if (selected == null || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从备份恢复账本'),
        content: const Text('系统会先校验全部记录、照片和哈希。任何失败都不会创建不完整账本。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('校验并恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true)
      await controller.restoreFreshInstall(File(selected.path));
  }

  Future<void> _loadSample(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('载入模拟账本'),
        content: const Text(
          '将向调试版独立数据库写入 3 条加班和 1 条调休记录，不连接 Supabase，也不会触碰正式应用数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认载入'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.loadDebugSampleData();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('载入失败：$error')));
    }
  }
}
