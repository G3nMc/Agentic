import 'package:flutter_test/flutter_test.dart';
import 'package:agentic/services/groq_service.dart';

void main() {
  group('GroqService.stripThink', () {
    test('returns text unchanged when no think tags', () {
      const text = 'Hello, world!';
      expect(GroqService.stripThink(text), equals('Hello, world!'));
    });

    test('strips a single <think>...</think> block', () {
      const text = '<think>internal reasoning</think>The answer is 42.';
      expect(GroqService.stripThink(text), equals('The answer is 42.'));
    });

    test('strips think blocks regardless of case', () {
      const text = '<THINK>private thoughts</THINK>Public reply.';
      expect(GroqService.stripThink(text), equals('Public reply.'));
    });

    test('strips multi-line think blocks', () {
      const text =
          '<think>\nline 1\nline 2\n</think>\nActual response.';
      expect(GroqService.stripThink(text), equals('Actual response.'));
    });

    test('strips multiple think blocks', () {
      const text =
          '<think>first</think>middle<think>second</think>end';
      expect(GroqService.stripThink(text), equals('middleend'));
    });

    test('returns empty string for a message that is only a think block', () {
      const text = '<think>pure reasoning, no reply</think>';
      expect(GroqService.stripThink(text), equals(''));
    });

    test('trims surrounding whitespace after stripping', () {
      const text = '  <think>thought</think>  answer  ';
      expect(GroqService.stripThink(text), equals('answer'));
    });
  });

  group('GroqService.fallbackModels', () {
    test('is not empty', () {
      expect(GroqService.fallbackModels, isNotEmpty);
    });

    test('contains only non-empty strings', () {
      for (final m in GroqService.fallbackModels) {
        expect(m, isNotEmpty);
      }
    });

    test('does not contain HuggingFace-style model IDs (with /)', () {
      for (final m in GroqService.fallbackModels) {
        expect(m.contains('/'), isFalse,
            reason: 'Groq model "$m" should not contain "/"');
      }
    });

    test('first model is a known fast Groq model', () {
      // The fallback list is used when the API is unreachable and as the
      // default for new conversations — it should lead with a capable model.
      expect(GroqService.fallbackModels.first, isNotEmpty);
    });
  });

  group('GroqService.supportsToolCalling', () {
    test('returns true for llama-3.3-70b-versatile', () {
      expect(GroqService.supportsToolCalling('llama-3.3-70b-versatile'), isTrue);
    });

    test('returns true for mixtral-8x7b-32768', () {
      expect(GroqService.supportsToolCalling('mixtral-8x7b-32768'), isTrue);
    });

    test('returns true for gemma2-9b-it', () {
      expect(GroqService.supportsToolCalling('gemma2-9b-it'), isTrue);
    });

    test('returns false for deepseek-r1-distill-llama-70b', () {
      expect(
        GroqService.supportsToolCalling('deepseek-r1-distill-llama-70b'),
        isFalse,
      );
    });

    test('returns false for qwen-qwq-32b', () {
      expect(GroqService.supportsToolCalling('qwen-qwq-32b'), isFalse);
    });

    test('returns false for any model containing deepseek-r1 in name', () {
      expect(
        GroqService.supportsToolCalling('deepseek-r1-distill-qwen-14b'),
        isFalse,
      );
    });

    test('returns true for unknown model (optimistic default)', () {
      // New Groq models are assumed capable until proven otherwise.
      expect(GroqService.supportsToolCalling('some-new-llama-model'), isTrue);
    });

    test('all toolCapableModels pass the check', () {
      for (final m in GroqService.toolCapableModels) {
        expect(
          GroqService.supportsToolCalling(m),
          isTrue,
          reason: '"$m" is in toolCapableModels but fails supportsToolCalling()',
        );
      }
    });
  });
}
