/// Tests for the Gemini model-resolution logic used by the Gemini
/// orchestrator backend.
///
/// The rule is:
///   - Use `modelId` when it is a Gemini-style model name.
///   - Fall back to `savedModel` when `modelId` looks like an HF model ID.
///   - Fall back to the app default when both are empty.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hf_chat_flutter/data/repositories/backend_settings_repository.dart';
import 'package:hf_chat_flutter/services/llm_service.dart';

void main() {
  group('Gemini model resolution', () {
    test('uses conversation modelId when it looks like a Gemini model', () {
      expect(
        resolveGeminiModel('gemini-2.5-pro', 'gemini-2.5-flash'),
        equals('gemini-2.5-pro'),
      );
    });

    test('falls back to savedModel when modelId contains "/" (HF model ID)', () {
      expect(
        resolveGeminiModel(
          'HuggingFaceH4/zephyr-7b-beta',
          'gemini-2.5-flash',
        ),
        equals('gemini-2.5-flash'),
      );
    });

    test('falls back to default Gemini model when both are empty', () {
      expect(
        resolveGeminiModel('', ''),
        equals(BackendSettingsRepository.defaultGeminiModel),
      );
    });

    test('uses savedModel when modelId is empty', () {
      expect(
        resolveGeminiModel('', 'gemini-2.5-pro'),
        equals('gemini-2.5-pro'),
      );
    });
  });
}
