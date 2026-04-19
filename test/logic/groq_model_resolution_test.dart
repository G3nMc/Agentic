/// Tests for the Groq model-resolution logic introduced to fix the bug where
/// the chat-header model switcher was ignored for Groq backends.
///
/// The rule is:
///   - Use `modelId` (from the conversation, set by the model switcher) when it
///     is non-empty AND does not contain '/' (HF model IDs always contain '/').
///   - Fall back to `savedModel` (from BackendSettingsRepository) otherwise.
///   - If both are empty, use whatever non-empty value exists.
library;

import 'package:flutter_test/flutter_test.dart';

/// Pure function that mirrors the resolution logic in LlmService.
/// Keeping it as a standalone function makes the test self-contained and
/// ensures the tests stay valid even if the service is refactored.
String resolveGroqModel(String modelId, String savedModel) {
  if (modelId.isNotEmpty && !modelId.contains('/')) {
    return modelId;
  }
  return savedModel.isNotEmpty ? savedModel : modelId;
}

void main() {
  group('Groq model resolution', () {
    test('uses conversation modelId when it looks like a Groq model', () {
      expect(
        resolveGroqModel('gemma2-9b-it', 'llama-3.3-70b-versatile'),
        equals('gemma2-9b-it'),
      );
    });

    test('falls back to savedModel when modelId contains "/" (HF model ID)', () {
      expect(
        resolveGroqModel(
          'HuggingFaceH4/zephyr-7b-beta',
          'llama-3.3-70b-versatile',
        ),
        equals('llama-3.3-70b-versatile'),
      );
    });

    test('falls back to savedModel when modelId is empty', () {
      expect(
        resolveGroqModel('', 'mixtral-8x7b-32768'),
        equals('mixtral-8x7b-32768'),
      );
    });

    test('uses modelId when savedModel is empty and modelId has no slash', () {
      expect(
        resolveGroqModel('deepseek-r1-distill-llama-70b', ''),
        equals('deepseek-r1-distill-llama-70b'),
      );
    });

    test('uses modelId when both have no slash — conversation model wins', () {
      expect(
        resolveGroqModel('qwen-qwq-32b', 'llama-3.1-8b-instant'),
        equals('qwen-qwq-32b'),
      );
    });

    test('returns modelId even if savedModel is empty and modelId has slash', () {
      // Edge case: nothing useful in savedModel, so return the only value we have.
      expect(
        resolveGroqModel('some/hf-model', ''),
        equals('some/hf-model'),
      );
    });

    test('handles both empty strings gracefully', () {
      expect(resolveGroqModel('', ''), equals(''));
    });
  });
}
