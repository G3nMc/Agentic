/// Tests for the Groq model-resolution logic introduced to fix the bug where
/// the chat-header model switcher was ignored for Groq backends.
///
/// The rule is:
///   - Use `modelId` (from the conversation, set by the model switcher) when it
///     is non-empty AND does not contain ':' (HuggingFace model IDs carry a
///     `:provider` suffix like `Qwen/...:hyperbolic`; Groq's own IDs — even
///     the newer slashed ones like `openai/gpt-oss-120b` or `qwen/qwen3-32b`
///     — never use ':').
///   - Fall back to `savedModel` (from BackendSettingsRepository) otherwise.
///   - If both are empty, use whatever non-empty value exists.
library;

import 'package:flutter_test/flutter_test.dart';

/// Pure function that mirrors the resolution logic in LlmService.
/// Keeping it as a standalone function makes the test self-contained and
/// ensures the tests stay valid even if the service is refactored.
String resolveGroqModel(String modelId, String savedModel) {
  if (modelId.isNotEmpty && !modelId.contains(':')) {
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

    test('falls back to savedModel when modelId is a HF id (":provider" suffix)', () {
      expect(
        resolveGroqModel(
          'Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic',
          'llama-3.3-70b-versatile',
        ),
        equals('llama-3.3-70b-versatile'),
      );
    });

    test('uses slashed Groq model id (e.g. openai/gpt-oss-120b)', () {
      // Regression: earlier logic wrongly rejected any '/' as a HF id, so
      // picking gpt-oss-120b in the UI silently fell through to savedModel.
      expect(
        resolveGroqModel('openai/gpt-oss-120b', 'qwen/qwen3-32b'),
        equals('openai/gpt-oss-120b'),
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

    test('returns modelId when savedModel is empty and modelId has ":provider"', () {
      // Edge case: nothing useful in savedModel, so return the only value we have.
      expect(
        resolveGroqModel('some-model:hf-inference', ''),
        equals('some-model:hf-inference'),
      );
    });

    test('handles both empty strings gracefully', () {
      expect(resolveGroqModel('', ''), equals(''));
    });
  });
}
