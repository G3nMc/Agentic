import 'package:flutter_test/flutter_test.dart';
import 'package:agentic/data/repositories/backend_settings_repository.dart';
import 'package:agentic/services/llm_service.dart';

void main() {
  final repo = BackendSettingsRepository.instance;

  group('BackendSettingsRepository.parseBackend', () {
    // Round-trip test: every LlmBackend.name should parse back to itself.
    for (final backend in LlmBackend.values) {
      test('round-trips ${backend.name}', () {
        final parsed = repo.parseBackend(backend.name);
        expect(parsed, equals(backend));
      });
    }

    test('parses legacy "LlmBackend.<variant>" form', () {
      expect(
        repo.parseBackend('LlmBackend.ollama'),
        equals(LlmBackend.ollama),
      );
      expect(
        repo.parseBackend('LlmBackend.groqOrchestrator'),
        equals(LlmBackend.groqOrchestrator),
      );
    });

    test('defaults to huggingFace for unknown values', () {
      expect(repo.parseBackend(''), equals(LlmBackend.huggingFace));
      expect(repo.parseBackend('notABackend'), equals(LlmBackend.huggingFace));
    });

    test('parses every backend variant by name', () {
      final cases = {
        'huggingFace': LlmBackend.huggingFace,
        'local': LlmBackend.local,
        'orchestrator': LlmBackend.orchestrator,
        'ollama': LlmBackend.ollama,
        'ollamaPython': LlmBackend.ollamaPython,
        'ollamaOrchestrator': LlmBackend.ollamaOrchestrator,
        'groq': LlmBackend.groq,
        'groqOrchestrator': LlmBackend.groqOrchestrator,
        'geminiOrchestrator': LlmBackend.geminiOrchestrator,
        'openRouter': LlmBackend.openRouter,
        'ollamaGenerate': LlmBackend.ollamaGenerate,
      };
      for (final entry in cases.entries) {
        expect(
          repo.parseBackend(entry.key),
          equals(entry.value),
          reason: 'parseBackend("${entry.key}") should return ${entry.value}',
        );
      }
    });
  });

  group('BackendSettingsRepository defaults', () {
    test('default Groq temperature is in valid range', () {
      const t = BackendSettingsRepository.defaultGroqTemperature;
      expect(t, greaterThanOrEqualTo(0.0));
      expect(t, lessThanOrEqualTo(2.0));
    });

    test('default Groq max tokens is positive', () {
      expect(BackendSettingsRepository.defaultGroqMaxTokens, greaterThan(0));
    });

    test('default Gemini temperature is in valid range', () {
      const t = BackendSettingsRepository.defaultGeminiTemperature;
      expect(t, greaterThanOrEqualTo(0.0));
      expect(t, lessThanOrEqualTo(2.0));
    });

    test('default Gemini max tokens is positive', () {
      expect(BackendSettingsRepository.defaultGeminiMaxTokens, greaterThan(0));
    });

    test('default Gemini model is non-empty', () {
      expect(BackendSettingsRepository.defaultGeminiModel, isNotEmpty);
    });

    test('default OpenRouter temperature is in valid range', () {
      const t = BackendSettingsRepository.defaultOpenRouterTemperature;
      expect(t, greaterThanOrEqualTo(0.0));
      expect(t, lessThanOrEqualTo(2.0));
    });

    test('default OpenRouter max tokens is positive', () {
      expect(
        BackendSettingsRepository.defaultOpenRouterMaxTokens,
        greaterThan(0),
      );
    });

    test('default Ollama temperature is in valid range', () {
      const t = BackendSettingsRepository.defaultOllamaTemperature;
      expect(t, greaterThanOrEqualTo(0.0));
      expect(t, lessThanOrEqualTo(2.0));
    });

    test('default Ollama numPredict is positive', () {
      expect(BackendSettingsRepository.defaultOllamaNumPredict, greaterThan(0));
    });

    test('default Ollama numCtx is positive', () {
      expect(BackendSettingsRepository.defaultOllamaNumCtx, greaterThan(0));
    });
  });
}
