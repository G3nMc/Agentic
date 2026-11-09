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
    String taskMode = 'auto_input', // user_input / auto_input
    bool? thinking, // Thinking ON/OFF; null = keep the launch-time slot value
    String? effort, // Effort level: minimal/low/medium/high/max
  }) async {
    // Bind this send to its conversation for the whole async scope. Every
    // unkeyed orchestrator call below (isRunning, start, requestRestart,
    // sendPrompt, stderrLog…) then resolves against *this* chat's session,
    // even while another conversation is doing the same thing concurrently.
    // Without it, opening chat B mid-turn would restart chat A's process.
    if (conversationId != null && conversationId.isNotEmpty) {
      return OrchestratorManager.instance.withConversation(
        conversationId,
        () => _sendChatInternal(
          backend: backend,
          token: token,
          modelId: modelId,
          history: history,
          conversationId: conversationId,
          localServerUrl: localServerUrl,
          ollamaBaseUrl: ollamaBaseUrl,
          ollamaModelId: ollamaModelId,
          ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
          contextSummary: contextSummary,
          temperature: temperature,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
        ),
      );
    }
    return _sendChatInternal(
      backend: backend,
      token: token,
      modelId: modelId,
      history: history,
      conversationId: conversationId,
      localServerUrl: localServerUrl,
      ollamaBaseUrl: ollamaBaseUrl,
      ollamaModelId: ollamaModelId,
      ollamaPythonBridgeUrl: ollamaPythonBridgeUrl,
      contextSummary: contextSummary,
      temperature: temperature,
      taskMode: taskMode,
      thinking: thinking,
      effort: effort,
    );
  }

  /// The backend dispatch itself, always executed inside
  /// [OrchestratorManager.withConversation] so its unkeyed orchestrator calls
  /// target the conversation that issued them.
  Future<String> _sendChatInternal({
    required LlmBackend backend,
    required String token,
    required String modelId,
    required List<ChatMessage> history,
    String? conversationId,
    String? localServerUrl,
    String? ollamaBaseUrl,
    String? ollamaModelId,
    String? ollamaPythonBridgeUrl,
    String? contextSummary,
    double? temperature,
    String taskMode = 'auto_input',
    bool? thinking,
    String? effort,
  }) async {
    // AUTO INPUT is MaM — Model against Model. The Assistant that answers and
    // the User that reviews and continues are the two models assigned in
    // Settings -> Workflow Agents MaM, and the multi-agent subprocess is the
    // one carrying those assignments. When it is already running, route the
    // turn straight into it: every per-backend branch below compares the
    // running backend/model/temperature against the single-model settings and
    // would stop + relaunch the subprocess, discarding the workflow agents the
    // chat header advertises.
    if (taskMode == 'auto_input' && OrchestratorManager.instance.isRunning) {
      final split =
          _splitPromptAndHistory(history, contextSummary: contextSummary);
      final prompt = split.prompt;
      if (prompt == null) throw Exception('No user message to send.');
      return OrchestratorManager.instance.sendPrompt(
        prompt,
        sessionKey: conversationId,
        seedHistory: split.seed,
        forceHistorySync: true,
        taskMode: taskMode,
        thinking: thinking,
        effort: effort,
      );
    }

    switch (backend) {
      case LlmBackend.orchestrator:
        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          final currentModel = OrchestratorManager.instance.currentModelId;
          final currentTemp = OrchestratorManager.instance.currentTemperature;
          if (currentBackend != OrchestratorBackend.huggingface ||
              currentModel != modelId ||
              currentTemp != temperature) {
            // Never kill a turn in flight: park the relaunch and let the
            // running answer land before the new configuration takes over.
            OrchestratorManager.instance.requestRestart(
              reason: 'huggingface model/temperature drift',
              source: OrchestratorStopSource.modelSwitch,
              argsFingerprint: OrchestratorManager.fingerprintFor(
                backend: OrchestratorBackend.huggingface,
                modelId: modelId,
                temperature: temperature,
              ),
            );
          }
        }

        if (!OrchestratorManager.instance.isRunning) {
          final started = await OrchestratorManager.instance.start(
            hfToken: token,
            modelId: modelId,
            backend: OrchestratorBackend.huggingface,
            temperature: temperature,
          );
          if (!started) {
            throw Exception(
              "Failed to start orchestrator. "
              "Check that Python and dependencies are installed (Settings > Install Dependencies). "
              "stderr: ${OrchestratorManager.instance.stderrLog}",
            );
          }
        }

        final split = _splitPromptAndHistory(history, contextSummary: contextSummary);
        final prompt = split.prompt;
        if (prompt == null) {
          throw Exception("No user message to send.");
        }
        return OrchestratorManager.instance.sendPrompt(
          prompt,
          sessionKey: conversationId,
          seedHistory: split.seed,
          forceHistorySync: true,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
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
        final ollamaMaxTokens = await settings.getOllamaNumPredict();
        final ollamaNumCtx = await settings.getOllamaNumCtx();
        final ollamaAutoNumCtx = await settings.getOllamaAutoNumCtx();
        final ollamaBaseUrl = await settings.getOllamaBaseUrl();

        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          final currentModel = OrchestratorManager.instance.currentModelId;
          final currentTemp = OrchestratorManager.instance.currentTemperature;
          if (currentBackend != OrchestratorBackend.ollama ||
              currentModel != resolvedOllamaModel ||
              currentTemp != temperature) {
            // Never kill a turn in flight: park the relaunch and let the
            // running answer land before the new configuration takes over.
            OrchestratorManager.instance.requestRestart(
              reason: 'ollama model/temperature drift',
              source: OrchestratorStopSource.modelSwitch,
              argsFingerprint: OrchestratorManager.fingerprintFor(
                backend: OrchestratorBackend.ollama,
                modelId: resolvedOllamaModel,
                temperature: temperature,
                maxTokens: ollamaMaxTokens,
              ),
            );
          }
        }
        if (!OrchestratorManager.instance.isRunning) {
          final started = await OrchestratorManager.instance.start(
            modelId: resolvedOllamaModel,
            backend: OrchestratorBackend.ollama,
            ollamaBaseUrl: ollamaBaseUrl,
            ollamaNumCtx: ollamaNumCtx,
            ollamaAutoNumCtx: ollamaAutoNumCtx,
            ollamaApiKey: ollamaApiKey,
            temperature: temperature,
            maxTokens: ollamaMaxTokens,
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

        final split = _splitPromptAndHistory(history, contextSummary: contextSummary);
        final prompt = split.prompt;
        if (prompt == null) {
          throw Exception("No user message to send.");
        }
        return OrchestratorManager.instance.sendPrompt(
          prompt,
          sessionKey: conversationId,
          seedHistory: split.seed,
          forceHistorySync: true,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
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

        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          final currentModel = OrchestratorManager.instance.currentModelId;
          final currentTemp = OrchestratorManager.instance.currentTemperature;
          if (currentBackend != OrchestratorBackend.groq ||
              currentModel != groqModel ||
              currentTemp != temperature) {
            await OrchestratorManager.instance.stop();
          }
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
        final split = _splitPromptAndHistory(history, contextSummary: contextSummary);
        final prompt = split.prompt;
        if (prompt == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          prompt,
          sessionKey: conversationId,
          seedHistory: split.seed,
          forceHistorySync: true,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
        );

      case LlmBackend.geminiOrchestrator:
        final settings = BackendSettingsRepository.instance;
        final geminiKey = await settings.getGeminiApiKey() ?? '';
        final savedGeminiModel = await settings.getGeminiModel() ?? '';
        final geminiModel = resolveGeminiModel(modelId, savedGeminiModel);
        final temperature = await settings.getGeminiTemperature();
        final maxTokens = await settings.getGeminiMaxTokens();
        final tpmLimit = await settings.getGeminiTpmLimit();

        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          final currentModel = OrchestratorManager.instance.currentModelId;
          final currentTemp = OrchestratorManager.instance.currentTemperature;
          if (currentBackend != OrchestratorBackend.gemini ||
              currentModel != geminiModel ||
              currentTemp != temperature) {
            // Never kill a turn in flight: park the relaunch and let the
            // running answer land before the new configuration takes over.
            OrchestratorManager.instance.requestRestart(
              reason: 'gemini model/temperature drift',
              source: OrchestratorStopSource.modelSwitch,
              argsFingerprint: OrchestratorManager.fingerprintFor(
                backend: OrchestratorBackend.gemini,
                modelId: geminiModel,
                temperature: temperature,
                maxTokens: maxTokens,
              ),
            );
          }
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

        final split = _splitPromptAndHistory(history, contextSummary: contextSummary);
        final prompt = split.prompt;
        if (prompt == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          prompt,
          sessionKey: conversationId,
          seedHistory: split.seed,
          forceHistorySync: true,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
        );

      case LlmBackend.openRouterOrchestrator:
        final orSettings = BackendSettingsRepository.instance;
        final orKey = await orSettings.getOpenRouterApiKey() ?? '';
        final orSavedModel = await orSettings.getOpenRouterModel() ?? '';
        final orModel = resolveOpenRouterModel(modelId, orSavedModel);
        final orTemperature = await orSettings.getOpenRouterTemperature();
        final orMaxTokens = await orSettings.getOpenRouterMaxTokens();
        final orContextLimit = await orSettings.getOpenRouterContextLimit();// Removed
        final orTpmLimit = await orSettings.getOpenRouterTpmLimit();

        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          final currentModel = OrchestratorManager.instance.currentModelId;
          final currentTemp = OrchestratorManager.instance.currentTemperature;
          if (currentBackend != OrchestratorBackend.openrouter ||
              currentModel != orModel ||
              currentTemp != orTemperature) {
            // Never kill a turn in flight: park the relaunch and let the
            // running answer land before the new configuration takes over.
            OrchestratorManager.instance.requestRestart(
              reason: 'openrouter model/temperature drift',
              source: OrchestratorStopSource.modelSwitch,
              argsFingerprint: OrchestratorManager.fingerprintFor(
                backend: OrchestratorBackend.openrouter,
                modelId: orModel,
                temperature: orTemperature,
                maxTokens: orMaxTokens,
              ),
            );
          }
        }
        if (!OrchestratorManager.instance.isRunning) {
          bool started = await OrchestratorManager.instance.start(
            modelId: orModel,
            backend: OrchestratorBackend.openrouter,
            openRouterApiKey: orKey,
            openRouterContextLimit: orContextLimit,
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
        final split = _splitPromptAndHistory(history, contextSummary: contextSummary);
        final prompt = split.prompt;
        if (prompt == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          prompt,
          sessionKey: conversationId,
          seedHistory: split.seed,
          forceHistorySync: true,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
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

        if (OrchestratorManager.instance.isRunning) {
          final currentBackend = OrchestratorManager.instance.currentBackend;
          final currentModel = OrchestratorManager.instance.currentModelId;
          final currentTemp = OrchestratorManager.instance.currentTemperature;
          if (currentBackend != OrchestratorBackend.github ||
              currentModel != ghModel ||
              currentTemp != ghTemperature) {
            // Never kill a turn in flight: park the relaunch and let the
            // running answer land before the new configuration takes over.
            OrchestratorManager.instance.requestRestart(
              reason: 'github models model/temperature drift',
              source: OrchestratorStopSource.modelSwitch,
              argsFingerprint: OrchestratorManager.fingerprintFor(
                backend: OrchestratorBackend.github,
                modelId: ghModel,
                temperature: ghTemperature,
                maxTokens: ghMaxTokens,
              ),
            );
          }
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
        final split = _splitPromptAndHistory(history, contextSummary: contextSummary);
        final prompt = split.prompt;
        if (prompt == null) throw Exception('No user message to send.');
        return OrchestratorManager.instance.sendPrompt(
          prompt,
          sessionKey: conversationId,
          seedHistory: split.seed,
          forceHistorySync: true,
          taskMode: taskMode,
          thinking: thinking,
          effort: effort,
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

  /// Split the visible chat into the prompt and the seed history using a
  /// single index, mirroring the backend's debug-mode ``_read_last_user_turn``:
  /// the prompt is the last user turn, and the seed history is every
  /// non-hidden turn *before* it. Because both halves derive from the same
  /// index, the prompt can never also appear inside the seed history (the
  /// duplicated-turn bug that made the assistant reply with a terse "OK.").
  ({String? prompt, List<Map<String, String>> seed}) _splitPromptAndHistory(
    List<ChatMessage> history, {
    String? contextSummary,
  }) {
    // Locate the last user turn — its content is the prompt.
    var lastUserIdx = -1;
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].role == MessageRole.user) {
        lastUserIdx = i;
        break;
      }
    }

    final seed = <Map<String, String>>[];

    // Add context summary as a system message if provided.
    if (contextSummary != null && contextSummary.isNotEmpty) {
      seed.add({
        'role': 'system',
        'content': 'Context Summary: $contextSummary',
      });
    }

    // Seed history = every non-hidden turn strictly before the prompt.
    for (var i = 0; i < lastUserIdx; i++) {
      final m = history[i];
      if (m.hidden) continue;
      seed.add({
        'role': switch (m.role) {
          MessageRole.user => 'user',
          MessageRole.assistant => 'assistant',
          MessageRole.system => 'system',
        },
        'content': m.content,
      });
    }

    return (
      prompt: lastUserIdx >= 0 ? history[lastUserIdx].content : null,
      seed: seed,
    );
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

  /// Stop the orchestrator if it's running.
  ///
  /// This is a genuine teardown request (app shutdown / explicit user action),
  /// so it is allowed to terminate a turn that is still in flight.
  Future<void> stopOrchestrator() async {
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop(
        source: OrchestratorStopSource.appShutdown,
        reason: 'LlmService.stopOrchestrator',
      );
    }
  }
}
