import 'package:flutter/material.dart';

import '../app_controller.dart';
import 'overtime_page.dart';
import 'reconcile_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'app_palette.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var index = 0;

  @override
  Widget build(BuildContext context) {
    final sectionColor = switch (index) {
      0 => AppPalette.coralDeep,
      1 => AppPalette.tealDeep,
      _ => AppPalette.ink,
    };
    final indicatorColor = switch (index) {
      0 => AppPalette.coralSoft,
      1 => AppPalette.tealSoft,
      _ => AppPalette.goldSoft,
    };
    final pages = [
      OvertimePage(controller: widget.controller),
      ReconcilePage(controller: widget.controller),
      StatsPage(controller: widget.controller),
      SettingsPage(controller: widget.controller),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(
          ['记加班', '记调休', '统计', '设置'][index],
          style: TextStyle(color: sectionColor),
        ),
      ),
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBarTheme(
        data: Theme.of(context).navigationBarTheme.copyWith(
          indicatorColor: indicatorColor,
          iconTheme: WidgetStateProperty.resolveWith(
            (states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? sectionColor
                  : AppPalette.inkMuted,
            ),
          ),
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              color: states.contains(WidgetState.selected)
                  ? sectionColor
                  : AppPalette.inkMuted,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
        child: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (value) => setState(() => index = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.more_time_outlined),
              selectedIcon: Icon(Icons.more_time),
              label: '记加班',
            ),
            NavigationDestination(
              icon: Icon(Icons.event_available_outlined),
              selectedIcon: Icon(Icons.event_available),
              label: '记调休',
            ),
            NavigationDestination(
              icon: Icon(Icons.query_stats_outlined),
              selectedIcon: Icon(Icons.query_stats),
              label: '统计',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }
}
