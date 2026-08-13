import 'package:flutter/material.dart';

import 'app.dart';
import 'app_controller.dart';
import 'data/local_database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final database = await LocalDatabase.open();
  final controller = AppController(database);
  await controller.initialize();
  runApp(OverBalanceFlowApp(controller: controller));
}
