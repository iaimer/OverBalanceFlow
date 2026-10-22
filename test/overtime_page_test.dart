import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:over_balance_flow/app_controller.dart';
import 'package:over_balance_flow/data/local_database.dart';
import 'package:over_balance_flow/domain/overtime_record.dart';
import 'package:over_balance_flow/ui/app_palette.dart';
import 'package:over_balance_flow/ui/common.dart';
import 'package:over_balance_flow/ui/overtime_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory root;
  late LocalDatabase database;
  late _PageController controller;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('obf-overtime-page-');
    database = await LocalDatabase.open(
      databasePath: '${root.path}/test.db',
      rootDirectory: root,
    );
    controller = _PageController(database);
  });

  tearDown(() async {
    await database.close();
    await root.delete(recursive: true);
  });

  test('当天的新增加班结束时间使用当前时分', () {
    final initial = overtimeEndTimeInitial(
      selectedDate: DateTime(2026, 9, 18),
      now: DateTime(2026, 9, 18, 14, 23),
    );

    expect(initial, const TimeOfDay(hour: 14, minute: 23));
  });

  test('历史或未来日期不覆盖已有结束时间', () {
    expect(
      overtimeEndTimeInitial(
        selectedDate: DateTime(2026, 9, 17),
        now: DateTime(2026, 9, 18, 14, 23),
      ),
      isNull,
    );
    expect(
      overtimeEndTimeInitial(
        selectedDate: DateTime(2026, 9, 19),
        now: DateTime(2026, 9, 18, 14, 23),
      ),
      isNull,
    );
  });

  testWidgets('保存成功后不把刚保存的记录显示为自冲突', (tester) async {
    await tester.pumpWidget(_testApp(controller));

    await tester.tap(find.text('保存加班'));
    await tester.pump();

    expect(controller.saveCalls, 1);
    expect(controller.records, hasLength(1));
    expect(find.byType(OvertimeConflictNotice), findsNothing);
    expect(find.text('已保存'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '继续录入');
    await tester.pump();

    expect(find.byType(OvertimeConflictNotice), findsOneWidget);
    expect(find.text('保存加班'), findsOneWidget);
  });

  testWidgets('保存进行中快速重复点击不会发起第二次保存', (tester) async {
    final gate = Completer<void>();
    controller.saveGate = gate.future;
    await tester.pumpWidget(_testApp(controller));

    await tester.tap(find.text('保存加班'));
    await tester.pump();

    expect(controller.saveCalls, 1);
    expect(find.text('正在保存…'), findsOneWidget);
    await tester.tap(find.byType(FilledButton));
    expect(controller.saveCalls, 1);

    gate.complete();
    await tester.pump();
  });

  testWidgets('冲突提示使用可读的容器前景色', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: _testTheme,
        home: OvertimeConflictNotice(
          conflicts: [
            OvertimeRecord(
              id: 'conflict',
              otDate: '2026-09-18',
              startTime: '17:00',
              endTime: '18:00',
              duration: 1,
              totalHours: 1,
              remainingHours: 1,
              status: '待核销',
              memo: '',
              createdAt: '2026-09-18T00:00:00Z',
            ),
          ],
        ),
      ),
    );

    final text = tester.widget<Text>(find.textContaining('与已有加班记录重叠'));
    final container = tester.widget<Container>(find.byType(Container));
    final decoration = container.decoration! as BoxDecoration;

    expect(decoration.color, _testTheme.colorScheme.errorContainer);
    expect(text.style?.color, _testTheme.colorScheme.onErrorContainer);
    expect(
      _contrastRatio(text.style!.color!, decoration.color!),
      greaterThanOrEqualTo(4.5),
    );
  });
}

final _testTheme = ThemeData(
  useMaterial3: true,
  colorScheme: const ColorScheme.light(
    primary: AppPalette.tealDeep,
    onPrimary: AppPalette.surface,
    surface: AppPalette.surface,
    onSurface: AppPalette.ink,
    error: Color(0xFFB94343),
    onError: Color(0xFFFFFFFF),
    errorContainer: AppPalette.coralSoft,
    onErrorContainer: Color(0xFF7A2424),
  ),
);

MaterialApp _testApp(_PageController controller) => MaterialApp(
  theme: _testTheme,
  home: Scaffold(body: OvertimePage(controller: controller)),
);

double _contrastRatio(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  final high = first > second ? first : second;
  final low = first > second ? second : first;
  return (high + 0.05) / (low + 0.05);
}

class _PageController extends AppController {
  _PageController(super.database);

  int saveCalls = 0;
  Future<void>? saveGate;

  @override
  Future<void> addOvertime({
    required DateTime date,
    required String start,
    required String end,
    required String memo,
    XFile? photo,
  }) async {
    saveCalls++;
    final gate = saveGate;
    if (gate != null) await gate;
    final hours = duration(start, end, date);
    records = [
      OvertimeRecord(
        id: 'saved-once',
        otDate: date.toIso8601String().substring(0, 10),
        startTime: start,
        endTime: end,
        duration: hours,
        totalHours: hours,
        remainingHours: hours,
        status: '待核销',
        memo: memo,
        createdAt: '2026-09-18T12:00:00Z',
      ),
    ];
    notifyListeners();
  }
}
