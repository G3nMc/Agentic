import 'package:flutter_test/flutter_test.dart';
import 'package:hf_chat_flutter/services/openrouter_service.dart';

void main() {
  group('OpenRouterService.stripThink', () {
    test('returns text unchanged when no think tags exist', () {
      const text = 'Hello from OpenRouter';
      expect(OpenRouterService.stripThink(text), equals(text));
    });

    test('strips a single think block', () {
      const text = '<think>internal</think>Visible answer';
      expect(
        OpenRouterService.stripThink(text),
        equals('Visible answer'),
      );
    });

    test('strips multi-line think blocks', () {
      const text = '<think>\nplan\nmore plan\n</think>\nFinal answer';
      expect(
        OpenRouterService.stripThink(text),
        equals('Final answer'),
      );
    });
  });

  group('OpenRouterService.fallbackModels', () {
    test('is not empty', () {
      expect(OpenRouterService.fallbackModels, isNotEmpty);
    });

    test('contains provider-prefixed model ids', () {
      for (final model in OpenRouterService.fallbackModels) {
        expect(model, contains('/'));
        expect(model, isNotEmpty);
      }
    });
  });
}
