import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'utils/defaults.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise sqflite backend (ffi on desktop).
  AppDatabase.configurePlatform();

  // Seed the default model on very first launch so the user sees
  // the same model id as HF.html pre-filled.
  await seedDefaults();

  runApp(const HfChatApp());
}