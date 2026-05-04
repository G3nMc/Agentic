import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'services/project_service.dart';
import 'utils/defaults.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise sqflite backend (ffi on desktop).
  AppDatabase.configurePlatform();

  // Seed the default model on very first launch so the user sees
  // the same model id as HF.html pre-filled.
  await seedDefaults();

  // Restore the persisted project folder so the orchestrator's --base-path
  // points at the user's project, not the app install dir.
  await ProjectService().init();

  runApp(const HfChatApp());
}