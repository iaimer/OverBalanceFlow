import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_controller.dart';
import '../domain/business_rules.dart';
import '../domain/holiday_calendar.dart';
import '../domain/overtime_record.dart';
import 'common.dart';
import 'app_palette.dart';
import 'overtime_editor_page.dart';

TimeOfDay? overtimeEndTimeInitial({
  required DateTime selectedDate,
  required DateTime now,
}) {
  if (!DateUtils.isSameDay(selectedDate, now)) return null;
  return TimeOfDay.fromDateTime(now);
}

enum _OvertimeSaveState { editing, saving, saved }

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
  var saveState = _OvertimeSaveState.editing;

  @override
  void dispose() {
    memo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = saveState != _OvertimeSaveState.saving;
    final recent = widget.controller.records
        .where((record) => !record.isLeave)
        .take(2)
        .toList();
    final estimated = widget.controller.duration(start, end, date);
    final conflicts = saveState == _OvertimeSaveState.saved
        ? const <OvertimeRecord>[]
        : findOverlappingOvertime(
            widget.controller.records,
            date: _dateText(date),
            startTime: start,
            endTime: end,
          );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('记录时间', style: TextStyle(color: AppPalette.inkMuted)),
            HelpTooltip(message: '保存后会按 FIFO 规则把这段加班时间加入可用调休余额。'),
          ],
        ),
        const SizedBox(height: 18),
        _Picker(
          label: '加班日期',
          value: date.toIso8601String().substring(0, 10),
          onTap: canEdit
              ? () async {
                  final value = await pickDate(context, date);
                  if (value != null && !_sameDay(value, date)) {
                    setState(() {
                      date = value;
                      saveState = _OvertimeSaveState.editing;
                    });
                  }
                }
              : null,
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
                onTap: canEdit
                    ? () async {
                        final value = await pickTime(context, start);
                        if (value != null && value != start) {
                          setState(() {
                            start = value;
                            saveState = _OvertimeSaveState.editing;
                          });
                        }
                      }
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Picker(
                label: '结束时间',
                value: end,
                onTap: canEdit
                    ? () async {
                        final now = DateTime.now();
                        final value = await pickTime(
                          context,
                          end,
                          initialTime: overtimeEndTimeInitial(
                            selectedDate: date,
                            now: now,
                          ),
                        );
                        if (value != null && value != end) {
                          setState(() {
                            end = value;
                            saveState = _OvertimeSaveState.editing;
                          });
                        }
                      }
                    : null,
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
          enabled: canEdit,
          onChanged: (_) {
            if (saveState != _OvertimeSaveState.editing) {
              setState(() => saveState = _OvertimeSaveState.editing);
            }
          },
          decoration: const InputDecoration(labelText: '备注（选填）'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: saveState == _OvertimeSaveState.saving
                    ? null
                    : () => _pickPhoto(ImageSource.camera),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('拍照'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: saveState == _OvertimeSaveState.saving
                    ? null
                    : () => _pickPhoto(ImageSource.gallery),
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
          onPressed:
              saveState == _OvertimeSaveState.editing && conflicts.isEmpty
              ? _save
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(switch (saveState) {
              _OvertimeSaveState.editing => '保存加班',
              _OvertimeSaveState.saving => '正在保存…',
              _OvertimeSaveState.saved => '已保存',
            }),
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
            onEdit: () => _openEditor(record),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (saveState != _OvertimeSaveState.editing) return;
    setState(() => saveState = _OvertimeSaveState.saving);
    try {
      await widget.controller.addOvertime(
        date: date,
        start: start,
        end: end,
        memo: memo.text.trim(),
        photo: photo,
      );
      if (!mounted) return;
      memo.clear();
      setState(() {
        photo = null;
        saveState = _OvertimeSaveState.saved;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加班已保存到 Supabase')));
    } catch (error) {
      if (!mounted) return;
      setState(() => saveState = _OvertimeSaveState.editing);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final value = await ImagePicker().pickImage(
      source: source,
      imageQuality: 82,
      maxWidth: 1600,
    );
    if (value != null && mounted) {
      setState(() {
        photo = value;
        saveState = _OvertimeSaveState.editing;
      });
    }
  }

  Future<void> _openEditor(OvertimeRecord record) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) =>
            OvertimeEditorPage(controller: widget.controller, record: record),
      ),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('加班记录已更新')));
    }
  }

  static String _dateText(DateTime value) =>
      value.toIso8601String().substring(0, 10);

  static bool _sameDay(DateTime first, DateTime second) =>
      DateUtils.isSameDay(first, second);
}

class _Picker extends StatelessWidget {
  const _Picker({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label;
  final String value;
  final VoidCallback? onTap;

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
