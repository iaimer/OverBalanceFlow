import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:over_balance_flow/ui/stats_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/app.dart';
import 'package:over_balance_flow/app_controller.dart';
import 'package:over_balance_flow/data/local_database.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/ui/reconcile_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late Directory root;
  late LocalDatabase db;
  late AppController controller;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('obf-leave-ui-');
    db = await LocalDatabase.open(
      databasePath: '${root.path}/db',
      rootDirectory: root,
    );
    controller = AppController(db)..loading = false;
    controller.annualRecords = [
      AnnualLeaveRecord(
        id: 'a',
        startDate: '2026-08-03',
        endDate: '2026-08-03',
        slots: const [AnnualLeaveSlot('2026-08-03', 'am')],
        createdAt: '2026-08-01T00:00:00Z',
      ),
    ];
  });
  tearDown(() async {
    controller.dispose();
    await db.close();
    await root.delete(recursive: true);
  });
  testWidgets('统计独立显示当前可用年假，窄屏无溢出并可查看年假记录', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: OverBalanceFlowApp(controller: controller),
      ),
    );
    await tester.tap(find.text('统计'));
    await tester.pumpAndSettle();
    expect(find.text('可用年假'), findsOneWidget);
    expect(find.text('4.5 天'), findsOneWidget);
    expect(find.text('0.0 小时'), findsOneWidget);
    expect(find.byType(DropdownButton<int>), findsNothing);
    expect(find.textContaining('额度'), findsNothing);
    expect(find.textContaining('已用'), findsNothing);
    final compRect = tester.getRect(find.byKey(const Key('comp-balance-card')));
    final annualRect = tester.getRect(
      find.byKey(const Key('annual-balance-card')),
    );
    expect(compRect.top, annualRect.top);
    expect(compRect.height, annualRect.height);
    expect(compRect.right, lessThan(annualRect.left));
    expect(tester.takeException(), isNull);
    const annualHelp = '每年提供 5 天年假，年底过期，不结转到下一年。';
    await tester.tap(find.bySemanticsLabel('说明：$annualHelp'));
    await tester.pump();
    expect(find.text(annualHelp), findsOneWidget);
    final output = Platform.environment['OBF_UI_QA_DIR'];
    if (output != null) {
      final fontPath = Platform.environment['OBF_QA_FONT'];
      if (fontPath != null) {
        await tester.runAsync(() async {
          final font = FontLoader('LocalCJK');
          font.addFont(
            File(
              fontPath,
            ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
          );
          await font.load();
          final iconsPath = Platform.environment['OBF_QA_ICONS'];
          if (iconsPath != null) {
            final icons = FontLoader('MaterialIcons');
            icons.addFont(
              File(
                iconsPath,
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
            await icons.load();
          }
        });
        final baseTheme = tester
            .widget<MaterialApp>(find.byType(MaterialApp))
            .theme!;
        final qaTheme = baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'LocalCJK'),
          primaryTextTheme: baseTheme.primaryTextTheme.apply(
            fontFamily: 'LocalCJK',
          ),
          appBarTheme: baseTheme.appBarTheme.copyWith(
            titleTextStyle: baseTheme.appBarTheme.titleTextStyle?.copyWith(
              fontFamily: 'LocalCJK',
            ),
          ),
        );
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: qaTheme,
              home: Scaffold(
                appBar: AppBar(title: const Text('统计')),
                body: StatsPage(controller: controller),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory(output).create(recursive: true);
          await File(
            '$output/stats.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    await tester.ensureVisible(find.text('年假').last);
    await tester.tap(find.text('年假').last);
    await tester.pumpAndSettle();
    expect(find.text('年假 0.5 天'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: StatsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 极大字体下仍应可滚动操作，不能因固定行宽溢出。
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: MaterialApp(
          builder: (_, child) => MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ReconcilePage(
              controller: controller,
              annualRecord: controller.annualRecords.single,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('新增调休余额不足时弹出提示且不显示成功', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReconcilePage(controller: controller)),
      ),
    );
    await tester.ensureVisible(find.text('预览 FIFO 核销'));
    await tester.tap(find.text('预览 FIFO 核销'));
    await tester.pumpAndSettle();
    expect(find.textContaining('调休余额不足'), findsOneWidget);
    expect(find.text('调休已入账'), findsNothing);
  });

  testWidgets('统计余额卡片在深色主题下保持同排布局', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: StatsPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    final compRect = tester.getRect(find.byKey(const Key('comp-balance-card')));
    final annualRect = tester.getRect(
      find.byKey(const Key('annual-balance-card')),
    );
    expect(compRect.top, annualRect.top);
    expect(compRect.height, annualRect.height);
    expect(tester.takeException(), isNull);
  });
}
