import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'ui/home_shell.dart';
import 'ui/migration_gate.dart';

class OverBalanceFlowApp extends StatelessWidget {
  const OverBalanceFlowApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xffa47716);
    return MaterialApp(
      title: '加班调休',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xfffaf9f6),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
          filled: true,
        ),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seed,
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
