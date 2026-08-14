import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../app_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});
  final AppController controller;
  static final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
    children: [
      Text('数据安全', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          controller.syncing
              ? Icons.sync
              : controller.syncError != null
              ? Icons.cloud_off_outlined
              : controller.usingOfflineCache
              ? Icons.cloud_off_outlined
              : Icons.cloud_done_outlined,
        ),
        title: Text(
          controller.syncing
              ? '正在同步云端账本'
              : controller.syncError != null && controller.records.isEmpty
              ? '尚未取得云端账本'
              : controller.usingOfflineCache
              ? '当前使用离线缓存'
              : 'Supabase 已同步',
        ),
        subtitle: Text(controller.syncError ?? '联网时以云端账本为准；同步失败不会清空有效缓存。'),
        trailing: controller.syncing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh),
        onTap: controller.syncing ? null : () => _refreshCloud(context),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.verified_user_outlined),
        title: const Text('历史迁移已校验'),
        subtitle: Text(_reportSummary(controller.migrationReport)),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.archive_outlined),
        title: const Text('导出 ZIP 备份'),
        subtitle: const Text('按“偷闲半日-备份-日期-时间.zip”命名；文件未加密，请妥善保存。'),
        onTap: () => _export(context),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.settings_backup_restore),
        title: const Text('从 ZIP 合并恢复'),
        subtitle: const Text('完整校验后合并到 Supabase，相同 UUID 使用备份版本。'),
        onTap: () => _restore(context),
      ),
      const SizedBox(height: 28),
      FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final info = snapshot.data;
          final version = info == null
              ? '正在读取版本信息'
              : '版本 ${info.version}（构建 ${info.buildNumber}）';
          return Semantics(
            label: '偷闲半日 $version',
            child: Center(
              child: Text(
                '偷闲半日 · $version',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.48),
                ),
              ),
            ),
          );
        },
      ),
    ],
  );

  Future<void> _export(BuildContext context) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = await controller.backupService.exportTo(directory);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: '偷闲半日本地备份（未加密）'),
      );
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(
          SnackBar(content: Text('备份已导出：${file.uri.pathSegments.last}')),
        );
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('备份失败：$error')));
    }
  }

  Future<void> _refreshCloud(BuildContext context) async {
    try {
      await controller.syncFromCloud();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('云端账本已刷新')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('刷新失败，继续使用现有缓存：$error')));
      }
    }
  }

  Future<void> _restore(BuildContext context) async {
    const group = XTypeGroup(label: '偷闲半日 ZIP 备份', extensions: ['zip']);
    final selected = await openFile(acceptedTypeGroups: [group]);
    final path = selected?.path;
    if (path == null) return;
    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认合并恢复'),
        content: const Text(
          '系统将先验证整个备份，再把记录与照片合并到 Supabase。相同 UUID 使用备份版本，不同 UUID 保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('继续恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.restoreBackupToCloud(File(path));
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('备份已校验并恢复到 Supabase')));
    } catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('恢复失败，线上原数据未被清空：$error')));
    }
  }

  String _reportSummary(String? raw) {
    if (raw == null) return '${controller.records.length} 条本地记录';
    try {
      final value = jsonDecode(raw) as Map<String, dynamic>;
      return '${value['record_count'] ?? controller.records.length} 条记录，UUID 和余额指纹通过';
    } catch (_) {
      return '${controller.records.length} 条本地记录';
    }
  }
}
