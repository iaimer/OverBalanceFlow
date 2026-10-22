import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:over_balance_flow/domain/annual_leave.dart';
import 'package:over_balance_flow/ui/annual_leave_widgets.dart';

void main() {
  testWidgets('年假卡片只显示当前年度可用天数', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnnualLeaveSummary(
            balance: AnnualLeaveBalance(
              2026,
              const [],
              now: DateTime(2026, 10, 22),
            ),
          ),
        ),
      ),
    );
    expect(find.text('可用年假'), findsOneWidget);
    expect(find.text('5.0 天'), findsOneWidget);
    expect(find.byType(DropdownButton<int>), findsNothing);
    expect(find.textContaining('额度'), findsNothing);
    expect(find.textContaining('已用'), findsNothing);
    expect(find.textContaining('小时'), findsNothing);
  });

  testWidgets('余额说明图标点击后显示 Tooltip', (tester) async {
    const message = '每年提供 5 天年假，年底过期，不结转到下一年。';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnnualLeaveSummary(
            balance: AnnualLeaveBalance(2026, const [], now: DateTime(2026)),
          ),
        ),
      ),
    );

    final info = find.bySemanticsLabel('说明：$message');
    expect(info, findsOneWidget);
    await tester.tap(info);
    await tester.pump();
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('说明图标支持鼠标悬停和长按', (tester) async {
    const message = '每年提供 5 天年假，年底过期，不结转到下一年。';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnnualLeaveSummary(
            balance: AnnualLeaveBalance(2026, const [], now: DateTime(2026)),
          ),
        ),
      ),
    );
    final icon = find.byType(IconButton);
    final center = tester.getCenter(icon);
    final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
    await mouse.addPointer(location: center);
    await mouse.moveTo(center);
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text(message), findsOneWidget);
    await mouse.moveTo(const Offset(-20, -20));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.longPress(icon);
    await tester.pump();
    expect(find.text(message), findsOneWidget);
    Tooltip.dismissAllToolTips();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text(message), findsOneWidget);
    await mouse.removePointer();
  });
}
