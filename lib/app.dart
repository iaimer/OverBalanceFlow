import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui/home_shell.dart';
import 'ui/migration_gate.dart';
import 'ui/app_palette.dart';

class OverBalanceFlowApp extends StatelessWidget {
  const OverBalanceFlowApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '偷闲半日',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          primary: AppPalette.tealDeep,
          onPrimary: AppPalette.surface,
          primaryContainer: AppPalette.tealSoft,
          onPrimaryContainer: AppPalette.ink,
          secondary: AppPalette.gold,
          onSecondary: AppPalette.ink,
          secondaryContainer: AppPalette.goldSoft,
          onSecondaryContainer: AppPalette.ink,
          tertiary: AppPalette.coral,
          onTertiary: AppPalette.surface,
          tertiaryContainer: AppPalette.coralSoft,
          onTertiaryContainer: AppPalette.ink,
          surface: AppPalette.surface,
          onSurface: AppPalette.ink,
          onSurfaceVariant: AppPalette.inkMuted,
          outline: AppPalette.outline,
          error: Color(0xFFB94343),
        ),
        scaffoldBackgroundColor: AppPalette.canvas,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppPalette.canvas,
          foregroundColor: AppPalette.ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          titleTextStyle: TextStyle(
            color: AppPalette.ink,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: AppPalette.surface,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: AppPalette.outline),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: AppPalette.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(12)),
            borderSide: BorderSide(color: AppPalette.tealDeep, width: 1.5),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppPalette.tealDeep,
            foregroundColor: AppPalette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: AppPalette.surface,
          indicatorColor: AppPalette.tealSoft,
          elevation: 0,
          labelTextStyle: WidgetStateProperty.resolveWith(
            (states) => TextStyle(
              color: states.contains(WidgetState.selected)
                  ? AppPalette.tealDeep
                  : AppPalette.inkMuted,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w700
                  : FontWeight.w500,
            ),
          ),
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppPalette.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          if (controller.loading) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (controller.migrationRequired)
            return MigrationGate(controller: controller);
          return HomeShell(controller: controller);
        },
      ),
    );
  }
}
