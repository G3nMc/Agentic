import 'package:your_app/data/repositories/model_repository.dart';
import 'package:your_app/data/repositories/settings_repository.dart';
import 'package:your_app/core/constants/api_constants.dart';
import 'package:your_app/data/models/hf_model.dart';

Future<void> seedDefaults() async {
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