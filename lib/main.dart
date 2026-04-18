import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database/app_database.dart';
import 'data/models/hf_model.dart';
import 'data/repositories/model_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'core/constants/api_constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialise sqflite backend (ffi on desktop).
  AppDatabase.configurePlatform();

  // Seed the default model on very first launch so the user sees
  // the same model id as HF.html pre-filled.
  await _seedDefaults();

  runApp(const HfChatApp());
}

Future<void> _seedDefaults() async {
  try {
    final selected = await SettingsRepository.instance.getSelectedModelId();
    if (selected == null || selected.isEmpty) {
      await SettingsRepository.instance
          .setSelectedModelId(ApiConstants.defaultModelId);
    }

    final models = await ModelRepository.instance.listAll();
    final alreadyHasDefault = models.any(
      (m) => m.id == ApiConstants.defaultModelId,
    );
    if (!alreadyHasDefault) {
      await ModelRepository.instance.upsert(
        HfModel(
          id: ApiConstants.defaultModelId,
          name: ApiConstants.defaultModelId,
          isFavorite: true,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  } catch (_) {
    // DB not ready (e.g. on web without ffi): ignore, user will configure later.
  }
}
