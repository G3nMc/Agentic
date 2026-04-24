library;

import 'package:flutter_test/flutter_test.dart';
import 'package:hf_chat_flutter/services/llm_service.dart';

void main() {
  group('OpenRouter model resolution', () {
    test('uses conversation model when it looks like an OpenRouter id', () {
      expect(
        resolveOpenRouterModel(
          'openai/gpt-5-mini',
          'google/gemini-2.5-flash',
        ),
        equals('openai/gpt-5-mini'),
      );
    });

    test('falls back to saved model for stale HF router ids', () {
      expect(
        resolveOpenRouterModel(
          'Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic',
          'anthropic/claude-sonnet-4.5',
        ),
        equals('anthropic/claude-sonnet-4.5'),
      );
    });

    test('falls back to saved model when conversation model is empty', () {
      expect(
        resolveOpenRouterModel('', 'google/gemini-2.5-flash'),
        equals('google/gemini-2.5-flash'),
      );
    });

    test('returns conversation model when saved model is empty', () {
      expect(
        resolveOpenRouterModel('anthropic/claude-sonnet-4.5', ''),
        equals('anthropic/claude-sonnet-4.5'),
      );
    });

    test('returns empty string when both values are empty', () {
      expect(resolveOpenRouterModel('', ''), equals(''));
    });

    test('detects provider-prefixed OpenRouter ids', () {
      expect(looksLikeOpenRouterModel('google/gemini-2.5-flash'), isTrue);
      expect(looksLikeOpenRouterModel('openai/gpt-5-mini'), isTrue);
    });

    test('rejects HF router ids with provider suffixes', () {
      expect(
        looksLikeOpenRouterModel(
          'Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic',
        ),
        isFalse,
      );
    });
  });
}
