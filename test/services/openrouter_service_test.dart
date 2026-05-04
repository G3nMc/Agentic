import 'package:flutter_test/flutter_test.dart';
import 'package:agentic/services/openrouter_service.dart';

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
}
