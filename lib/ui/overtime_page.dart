import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_controller.dart';
import '../domain/holiday_calendar.dart';
import 'common.dart';

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
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        Text('把今天的加班记清楚', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        _Picker(
          label: '加班日期',
          value: date.toIso8601String().substring(0, 10),
          onTap: () async {
            final value = await pickDate(context, date);
            if (value != null) setState(() => date = value);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, left: 4),
          child: Text(
            '系统判断：${widget.controller.dayType(date).label}',
            style: Theme.of(context).textTheme.bodySmall,
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
        TextField(
          controller: memo,
          decoration: const InputDecoration(labelText: '备注（选填）'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            final value = await ImagePicker().pickImage(
              source: ImageSource.camera,
              imageQuality: 82,
              maxWidth: 1600,
            );
            if (value != null) setState(() => photo = value);
          },
          icon: const Icon(Icons.photo_camera_outlined),
          label: Text(photo == null ? '拍摄打卡照片（选填）' : '已选择照片，点击重拍'),
        ),
        TextButton.icon(
          onPressed: () async {
            final value = await ImagePicker().pickImage(
              source: ImageSource.gallery,
              imageQuality: 82,
              maxWidth: 1600,
            );
            if (value != null) setState(() => photo = value);
          },
          icon: const Icon(Icons.photo_library_outlined),
          label: const Text('从相册选择'),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: saving ? null : _save,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(saving ? '正在保存…' : '保存加班'),
          ),
        ),
        const SizedBox(height: 30),
        Text('最近加班', style: Theme.of(context).textTheme.titleMedium),
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
        ).showSnackBar(const SnackBar(content: Text('加班已安全保存到本地')));
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
    } finally {
      if (mounted) setState(() => saving = false);
    }
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
