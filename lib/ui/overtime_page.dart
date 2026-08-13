import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_controller.dart';
import '../domain/holiday_calendar.dart';
import 'common.dart';
import 'app_palette.dart';

class OvertimePage extends StatefulWidget {
  const OvertimePage({super.key, required this.controller});
  final AppController controller;

  @override
  State<OvertimePage> createState() => _OvertimePageState();
}

class _OvertimePageState extends State<OvertimePage> {
  DateTime date = DateTime.now();
  String start = '17:00';
  String end = '18:00';
  final memo = TextEditingController();
  XFile? photo;
  bool saving = false;

  @override
  void dispose() {
    memo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recent = widget.controller.records
        .where((record) => !record.isLeave)
        .take(2)
        .toList();
    final estimated = widget.controller.duration(start, end, date);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        const Text(
          '记录时间，余额会自动进入 FIFO 账本。',
          style: TextStyle(color: AppPalette.inkMuted),
        ),
        const SizedBox(height: 18),
        _Picker(
          label: '加班日期',
          value: date.toIso8601String().substring(0, 10),
          onTap: () async {
            final value = await pickDate(context, date);
            if (value != null) setState(() => date = value);
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
                  if (value != null) setState(() => start = value);
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
                  if (value != null) setState(() => end = value);
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
        const SizedBox(height: 12),
        TextField(
          controller: memo,
          decoration: const InputDecoration(labelText: '备注（选填）'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('拍照'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickPhoto(ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('相册'),
              ),
            ),
          ],
        ),
        if (photo != null)
          const Padding(
            padding: EdgeInsets.only(top: 8, left: 4),
            child: Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: AppPalette.tealDeep),
                SizedBox(width: 6),
                Text(
                  '已选择打卡照片',
                  style: TextStyle(
                    color: AppPalette.tealDeep,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.coralDeep,
            foregroundColor: AppPalette.surface,
          ),
          onPressed: saving ? null : _save,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(saving ? '正在保存…' : '保存加班'),
          ),
        ),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('最近加班', style: Theme.of(context).textTheme.titleMedium),
            const Text('最近 2 条', style: TextStyle(color: AppPalette.inkMuted)),
          ],
        ),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('还没有加班记录'),
          ),
        ...recent.map(
          (record) => RecordTile(
            record: record,
            controller: widget.controller,
            compact: true,
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await widget.controller.addOvertime(
        date: date,
        start: start,
        end: end,
        memo: memo.text.trim(),
        photo: photo,
      );
      memo.clear();
      setState(() => photo = null);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加班已保存到 Supabase')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final value = await ImagePicker().pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (value != null && mounted) setState(() => photo = value);
  }
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
