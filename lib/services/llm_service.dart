import 'dart:io';

import '../data/models/message.dart';
import '../data/repositories/backend_settings_repository.dart';
import 'ollama_service.dart';
import 'orchestrator_manager.dart';
// ChatMessage.role is a MessageRole enum, not a String — imported above.

enum LlmBackend {
  @Deprecated('Use orchestrator variant instead')
  huggingFace,
  @Deprecated('Use orchestrator variant instead')
  local,
  orchestrator,
  @Deprecated('Use orchestrator variant instead')
  ollama,
  @Deprecated('Use orchestrator variant instead')
  ollamaPython,
  // Same filesystem-tool orchestrator as `orchestrator`, but the model
  // runs locally via Ollama instead of on the HF router. Needs Ollama
  // installed and a pulled model (preferably 7B+ for reliable tool use).
  ollamaOrchestrator,
  // Groq Cloud — ultra-fast inference via Groq's LPU hardware.
  // Requires a free API key from https://console.groq.com
  @Deprecated('Use orchestrator variant instead')
  groq,
  // Groq Cloud routed through the local orchestrator so Groq models
  // can use filesystem tools (read/write files, git, run commands).
  groqOrchestrator,
  // Gemini routed through the local orchestrator for filesystem tools.
  geminiOrchestrator,
  // OpenRouter direct chat-completions backend.
  @Deprecated('Use orchestrator variant instead')
  openRouter,
  // OpenRouter routed through the local orchestrator for filesystem tools.
  // Uses the same API key and model as the direct openRouter backend.
  openRouterOrchestrator,
  // GitHub Models routed through the local orchestrator for filesystem tools.
  // Uses a fine-grained GitHub PAT with the `models:read` scope.
  githubOrchestrator,
  // Direct /api/generate endpoint (Ollama-compatible).
  // Supports custom ports (e.g. localhost:12345), raw prompt templating,
  // and the `think` parameter for native reasoning output.
  // No native tool support — use ollamaOrchestrator for file/code tasks.
  @Deprecated('Use orchestrator variant instead')
  ollamaGenerate,
}

String resolveGeminiModel(String modelId, String savedModel) {
  if (modelId.isNotEmpty && !modelId.contains('/')) {
    return modelId;
  }
  if (savedModel.isNotEmpty) {
    return savedModel;
  }
  return BackendSettingsRepository.defaultGeminiModel;
}

bool looksLikeOpenRouterModel(String modelId) {
  final trimmed = modelId.trim();
  if (trimmed.isEmpty || trimmed.contains(':')) return false;
  return RegExp(r'^[a-z0-9._-]+/[a-z0-9._-]+$').hasMatch(trimmed);
}

String resolveOpenRouterModel(String modelId, String savedModel) {
  if (looksLikeOpenRouterModel(modelId)) {
    return modelId.trim();
  }
  if (savedModel.isNotEmpty) {
    return savedModel;
  }
  return modelId;
}

class LlmService {
  LlmService._();

  static final LlmService instance = LlmService._();

  String _extractOllamaKeyError(String stderr) {
    for (final raw in stderr.split('\n')) {
      final line = raw.trim();
      if (line.toLowerCase().startsWith('invalid ollama api key')) {
        return line;
      }
    }
    return '';
  }

  /// Unified interface to send chat using either remote or local backend
  Future<String> sendChat({
    required LlmBackend backend,
    required String token, // HF token (ignored for local/orchestrator/ollama/gemini)
    required String modelId,
    required List<ChatMessage> history,
    String? conversationId,
    String? localServerUrl, // e.g., "http://localhost:5000"
    String? ollamaBaseUrl, // e.g., "http://localhost:11434"
    String? ollamaModelId, // e.g., "llama3:latest"
    String? ollamaPythonBridgeUrl, // e.g., "http://127.0.0.1:11501"
    String? contextSummary, // Additional context summary to include
    double? temperature, // Optional temperature override
  }) async {
    switch (backend) {
      case LlmBackend.orchestrator:
        if (OrchestratorManager.instance.isRunning &&
            OrchestratorManager.instance.currentBackend !=
                OrchestratorBackend.huggingface) {
          await OrchestratorManager.instance.stop();
        }

        if (!OrchestratorManager.instance.isRunning) {
          final started = await OrchestratorManager.instance.start(
            hfToken: token,
            modelId: modelId,
            backend: OrchestratorBackend.huggingface,
          );
          if (!started) {
            throw Exception(
              "Failed to start orchestrator. "
              "Check that Python and dependencies are installed (Settings > Install Dependencies). "
              "stderr: ${OrchestratorManager.instance.stderrLog}",
            );
          }
        }

        final lastUser = _lastUserMessage(history);
        if (lastUser == null) {
          throw Exception("No user message to send.");
        }
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history, contextSummary: contextSummary),
          forceHistorySync: true,
        );

      case LlmBackend.ollamaOrchestrator:
        final resolvedOllamaModel =
            (ollamaModelId != null && ollamaModelId.isNotEmpty)
                ? ollamaModelId
                : modelId;
        if (resolvedOllamaModel.isEmpty) {
          throw Exception(
            "Ollama orchestrator: no model selected. Pull one in Settings "
            "→ 🦙 Ollama first (a 7B+ coder model is strongly recommended "
            "— 1-3B models frequently fail the tool-call protocol).",
          );
        }

        final settings = BackendSettingsRepository.instance;
        final ollamaApiKey = await settings.getOllamaApiKey() ?? '';

        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          if (currentBackend != OrchestratorBackend.ollama) {
            await OrchestratorManager.instance.stop();
          }
        }
        if (!OrchestratorManager.instance.isRunning) {
          final started = await OrchestratorManager.instance.start(
            modelId: resolvedOllamaModel,
            backend: OrchestratorBackend.ollama,
            ollamaBaseUrl: ollamaBaseUrl,
            ollamaApiKey: ollamaApiKey,
            temperature: temperature,
          );
          if (!started) {
            final stderr = OrchestratorManager.instance.stderrLog;
            final keyError = _extractOllamaKeyError(stderr);
            if (keyError.isNotEmpty) {
              throw Exception(keyError);
            }
            throw Exception(
              "Failed to start Ollama-backed orchestrator. Check that "
              "Python is installed and the Ollama daemon is running "
              "(Settings → 🦙 Ollama → Start Ollama server). "
              "stderr: $stderr",
            );
          }
        }

        final lastUser = _lastUserMessage(history);
        if (lastUser == null) {
          throw Exception("No user message to send.");
        }
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history, contextSummary: contextSummary),
          forceHistorySync: true,
        );

      case LlmBackend.groqOrchestrator:
        final settings = BackendSettingsRepository.instance;
        final groqKey = await settings.getGroqApiKey() ?? '';
        final savedModel = await settings.getGroqModel() ?? '';
        final groqModel = (modelId.isNotEmpty && !modelId.contains(':'))
            ? modelId
            : (savedModel.isNotEmpty ? savedModel : modelId);
        final temperature = await settings.getGroqTemperature();
        final maxTokens = await settings.getGroqMaxTokens();
        final tpmLimit = await settings.getGroqTpmLimit();

        if (OrchestratorManager.instance.isRunning &&
            OrchestratorManager.instance.currentBackend !=
                OrchestratorBackend.groq) {
          await OrchestratorManager.instance.stop();
        }
        if (!OrchestratorManager.instance.isRunning) {
          bool started = await OrchestratorManager.instance.start(
            modelId: groqModel,
            backend: OrchestratorBackend.groq,
            groqApiKey: groqKey,
            temperature: temperature,
            maxTokens: maxTokens,
            tpmLimit: tpmLimit,
          );

          if (!started) {
            final log = OrchestratorManager.instance.stderrLog;
            final isMissingDep =
                log.contains('Missing dependency') ||
                log.contains('ModuleNotFoundError') ||
                log.contains('No module named');
            if (isMissingDep) {
              final installed =
                  await OrchestratorManager.instance.installDependencies();
              if (installed) {
                started = await OrchestratorManager.instance.start(
                  modelId: groqModel,
                  backend: OrchestratorBackend.groq,
                  groqApiKey: groqKey,
                  temperature: temperature,
                  maxTokens: maxTokens,
                  tpmLimit: tpmLimit,
                );
              }
            }
          }

          if (!started) {
            throw Exception(
              'Failed to start Groq orchestrator. Check that Python and the '
              '`groq` package are installed (Settings → Install Dependencies). '
              'stderr: ${OrchestratorManager.instance.stderrLog}',
            );
          }
        }
        final lastUser = _lastUserMessage(history);
        if (lastUser == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history, contextSummary: contextSummary),
          forceHistorySync: true,
        );

      case LlmBackend.geminiOrchestrator:
        final settings = BackendSettingsRepository.instance;
        final geminiKey = await settings.getGeminiApiKey() ?? '';
        final savedGeminiModel = await settings.getGeminiModel() ?? '';
        final geminiModel = resolveGeminiModel(modelId, savedGeminiModel);
        final temperature = await settings.getGeminiTemperature();
        final maxTokens = await settings.getGeminiMaxTokens();
        final tpmLimit = await settings.getGeminiTpmLimit();

        if (OrchestratorManager.instance.isRunning &&
            OrchestratorManager.instance.currentBackend !=
                OrchestratorBackend.gemini) {
          await OrchestratorManager.instance.stop();
        }
        if (!OrchestratorManager.instance.isRunning) {
          bool started = await OrchestratorManager.instance.start(
            modelId: geminiModel,
            backend: OrchestratorBackend.gemini,
            geminiApiKey: geminiKey,
            temperature: temperature,
            maxTokens: maxTokens,
            tpmLimit: tpmLimit,
          );

          if (!started) {
            final log = OrchestratorManager.instance.stderrLog;
            final isMissingDep =
                log.contains('Missing dependency') ||
                log.contains('ModuleNotFoundError') ||
                log.contains('No module named');
            if (isMissingDep) {
              final installed =
                  await OrchestratorManager.instance.installDependencies();
              if (installed) {
                started = await OrchestratorManager.instance.start(
                  modelId: geminiModel,
                  backend: OrchestratorBackend.gemini,
                  geminiApiKey: geminiKey,
                  temperature: temperature,
                  maxTokens: maxTokens,
                  tpmLimit: tpmLimit,
                );
              }
            }
          }

          if (!started) {
            throw Exception(
              'Failed to start Gemini orchestrator. Check that Python and the '
              '`google-genai` package are installed (Settings -> Install Dependencies). '
              'stderr: ${OrchestratorManager.instance.stderrLog}',
            );
          }
        }

        final lastUser = _lastUserMessage(history);
        if (lastUser == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history, contextSummary: contextSummary),
          forceHistorySync: true,
        );

      case LlmBackend.openRouterOrchestrator:
        final orSettings = BackendSettingsRepository.instance;
        final orKey = await orSettings.getOpenRouterApiKey() ?? '';
        final orSavedModel = await orSettings.getOpenRouterModel() ?? '';
        final orModel = resolveOpenRouterModel(modelId, orSavedModel);
        final orTemperature = await orSettings.getOpenRouterTemperature();
        final orMaxTokens = await orSettings.getOpenRouterMaxTokens();
        final orTpmLimit = await orSettings.getOpenRouterTpmLimit();

        if (OrchestratorManager.instance.isRunning &&
            OrchestratorManager.instance.currentBackend !=
                OrchestratorBackend.openrouter) {
          await OrchestratorManager.instance.stop();
        }
        if (!OrchestratorManager.instance.isRunning) {
          bool started = await OrchestratorManager.instance.start(
            modelId: orModel,
            backend: OrchestratorBackend.openrouter,
            openRouterApiKey: orKey,
            temperature: orTemperature,
            maxTokens: orMaxTokens,
            tpmLimit: orTpmLimit,
          );

          if (!started) {
            final log = OrchestratorManager.instance.stderrLog;
            final isMissingDep =
                log.contains('Missing dependency') ||
                log.contains('ModuleNotFoundError') ||
                log.contains('No module named');
            if (isMissingDep) {
              final installed =
                  await OrchestratorManager.instance.installDependencies();
              if (installed) {
                started = await OrchestratorManager.instance.start(
                  modelId: orModel,
                  backend: OrchestratorBackend.openrouter,
                  openRouterApiKey: orKey,
                  temperature: orTemperature,
                  maxTokens: orMaxTokens,
                  tpmLimit: orTpmLimit,
                );
              }
            }
          }

          if (!started) {
            throw Exception(
              'Failed to start OpenRouter orchestrator. Check that Python is '
              'installed and your OpenRouter API key is set in Settings. '
              'stderr: ${OrchestratorManager.instance.stderrLog}',
            );
          }
        }
        final lastUser = _lastUserMessage(history);
        if (lastUser == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history, contextSummary: contextSummary),
          forceHistorySync: true,
        );

      case LlmBackend.githubOrchestrator:
        final ghSettings = BackendSettingsRepository.instance;
        final ghKey = await ghSettings.getGithubApiKey() ?? '';
        final ghSavedModel = await ghSettings.getGithubModel() ?? '';
        final ghModel = (modelId.isNotEmpty && modelId.contains('/'))
            ? modelId
            : ghSavedModel;
        final ghTemperature = await ghSettings.getGithubTemperature();
        final ghMaxTokens = await ghSettings.getGithubMaxTokens();
        final ghTpmLimit = await ghSettings.getGithubTpmLimit();
        final ghDisableTools = await ghSettings.getGithubDisableTools();

        if (OrchestratorManager.instance.isRunning &&
            OrchestratorManager.instance.currentBackend !=
                OrchestratorBackend.github) {
          await OrchestratorManager.instance.stop();
        }
        if (!OrchestratorManager.instance.isRunning) {
          bool started = await OrchestratorManager.instance.start(
            modelId: ghModel,
            backend: OrchestratorBackend.github,
            githubApiKey: ghKey,
            temperature: ghTemperature,
            maxTokens: ghMaxTokens,
            tpmLimit: ghTpmLimit,
            disableTools: ghDisableTools,
          );

          if (!started) {
            final log = OrchestratorManager.instance.stderrLog;
            final isMissingDep = log.contains('Missing dependency') ||
                log.contains('ModuleNotFoundError') ||
                log.contains('No module named');
            if (isMissingDep) {
              final installed =
                  await OrchestratorManager.instance.installDependencies();
              if (installed) {
                started = await OrchestratorManager.instance.start(
                  modelId: ghModel,
                  backend: OrchestratorBackend.github,
                  githubApiKey: ghKey,
                  temperature: ghTemperature,
                  maxTokens: ghMaxTokens,
                  tpmLimit: ghTpmLimit,
                );
              }
            }
          }

          if (!started) {
            throw Exception(
              'Failed to start GitHub Models orchestrator. Check that Python is '
              'installed and your GitHub PAT (with `models:read`) is set in Settings. '
              'stderr: ${OrchestratorManager.instance.stderrLog}',
            );
          }
        }
        final lastUser = _lastUserMessage(history);
        if (lastUser == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history, contextSummary: contextSummary),
          forceHistorySync: true,
        );

      case LlmBackend.huggingFace:
      case LlmBackend.local:
      case LlmBackend.ollama:
      case LlmBackend.ollamaPython:
      case LlmBackend.groq:
      case LlmBackend.openRouter:
      case LlmBackend.ollamaGenerate:
        throw UnsupportedError(
          'Direct backend $backend is no longer supported. '
          'Use the orchestrator variant instead (e.g. ollamaOrchestrator, groqOrchestrator).',
        );
    }
  }

  /// Extract the last user message from the chat history.
  /// NOTE: `ChatMessage.role` is a `MessageRole` enum — comparing it to the
  /// string `'user'` (as the previous version did) was always false, which
  /// is what produced the "No user message to send" exception.
  String? _lastUserMessage(List<ChatMessage> history) {
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == MessageRole.user) return history[i].content;
    }
    return null;
  }

  List<Map<String, String>> _seedHistoryForOrchestrator(
    List<ChatMessage> history, {
    String? contextSummary,
  }) {
    final List<Map<String, String>> result = [];
    
    // Add context summary as a system message if provided
    if (contextSummary != null && contextSummary.isNotEmpty) {
      result.add({
        'role': 'system',
        'content': 'Context Summary: $contextSummary',
      });
    }
    
    if (history.isEmpty) return result;
    final seed = history.sublist(0, history.length - 1);
    result.addAll(seed
        .map((m) => {
              'role': switch (m.role) {
                MessageRole.user => 'user',
                MessageRole.assistant => 'assistant',
                MessageRole.system => 'system',
              },
              'content': m.content,
            })
        .toList(growable: false));
    return result;
  }

  /// Check backend availability
  Future<bool> checkAvailability({
    required LlmBackend backend,
    String? token,
    String? localServerUrl,
    String? ollamaBaseUrl,
    String? ollamaPythonBridgeUrl,
  }) async {
    switch (backend) {
      case LlmBackend.orchestrator:
        return token != null && token.isNotEmpty;

      case LlmBackend.ollamaOrchestrator:
        return OllamaService.instance.isServerReachable(baseUrl: ollamaBaseUrl);

      case LlmBackend.groqOrchestrator:
        final key = await BackendSettingsRepository.instance.getGroqApiKey();
        final envKey = Platform.environment['GROQ_API_KEY'] ?? '';
        return (key != null && key.trim().isNotEmpty) || envKey.isNotEmpty;

      case LlmBackend.geminiOrchestrator:
        final key = await BackendSettingsRepository.instance.getGeminiApiKey();
        final envKey = Platform.environment['GOOGLE_API_KEY'] ??
            Platform.environment['GEMINI_API_KEY'] ??
            '';
        return (key != null && key.trim().isNotEmpty) || envKey.isNotEmpty;

      case LlmBackend.openRouterOrchestrator:
        final key =
            await BackendSettingsRepository.instance.getOpenRouterApiKey();
        final envKey = Platform.environment['OPENROUTER_API_KEY'] ?? '';
        return (key != null && key.trim().isNotEmpty) || envKey.isNotEmpty;

      case LlmBackend.githubOrchestrator:
        final key =
            await BackendSettingsRepository.instance.getGithubApiKey();
        final envKey = Platform.environment['GITHUB_TOKEN'] ??
            Platform.environment['GITHUB_API_KEY'] ??
            '';
        return (key != null && key.trim().isNotEmpty) || envKey.isNotEmpty;

      case LlmBackend.huggingFace:
      case LlmBackend.local:
      case LlmBackend.ollama:
      case LlmBackend.ollamaPython:
      case LlmBackend.groq:
      case LlmBackend.openRouter:
      case LlmBackend.ollamaGenerate:
        return false;
    }
  }

  /// Stop the orchestrator if it's running
  Future<void> stopOrchestrator() async {
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }
  }
}
