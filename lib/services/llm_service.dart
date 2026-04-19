import '../data/models/message.dart';
import '../data/repositories/backend_settings_repository.dart';
import 'groq_service.dart';
import 'huggingface_service.dart';
import 'local_llm_service.dart';
import 'ollama_python_manager.dart';
import 'ollama_service.dart';
import 'orchestrator_manager.dart';
// ChatMessage.role is a MessageRole enum, not a String — imported above.

enum LlmBackend {
  huggingFace,
  local,
  orchestrator,
  ollama,
  ollamaPython,
  // Same filesystem-tool orchestrator as `orchestrator`, but the model
  // runs locally via Ollama instead of on the HF router. Needs Ollama
  // installed and a pulled model (preferably 7B+ for reliable tool use).
  ollamaOrchestrator,
  // Groq Cloud — ultra-fast inference via Groq's LPU hardware.
  // Requires a free API key from https://console.groq.com
  groq,
  // Groq Cloud routed through the local orchestrator so Groq models
  // can use filesystem tools (read/write files, git, run commands).
  groqOrchestrator,
}

class LlmService {
  LlmService._();

  static final LlmService instance = LlmService._();

  /// Unified interface to send chat using either remote or local backend
  Future<String> sendChat({
    required LlmBackend backend,
    required String token, // HF token (ignored for local/orchestrator/ollama)
    required String modelId,
    required List<ChatMessage> history,
    String? conversationId,
    String? localServerUrl, // e.g., "http://localhost:5000"
    String? ollamaBaseUrl, // e.g., "http://localhost:11434"
    String? ollamaModelId, // e.g., "llama3:latest"
    String? ollamaPythonBridgeUrl, // e.g., "http://127.0.0.1:11501"
  }) async {
    switch (backend) {
      case LlmBackend.huggingFace:
        return HuggingFaceService.instance.sendChat(
          token: token,
          modelId: modelId,
          history: history,
        );

      case LlmBackend.local:
        if (localServerUrl == null || localServerUrl.isEmpty) {
          throw Exception("Local server URL not configured");
        }
        return LocalLlmService.instance.sendChat(
          serverUrl: localServerUrl,
          modelId: modelId,
          history: history,
        );

      case LlmBackend.ollama:
        final resolvedModel = (ollamaModelId != null && ollamaModelId.isNotEmpty)
            ? ollamaModelId
            : modelId;
        if (resolvedModel.isEmpty) {
          throw Exception(
              "Ollama: no model selected. Pull one from Settings first.");
        }
        // Honour user-tuned generation params from Settings. Default values
        // inside the repo match what the orchestrator uses so the two paths
        // behave the same when the user leaves defaults alone.
        final settings = BackendSettingsRepository.instance;
        final temperature = await settings.getOllamaTemperature();
        final numPredict = await settings.getOllamaNumPredict();
        final numCtx = await settings.getOllamaNumCtx();
        final apiKey = await settings.getOllamaApiKey();
        return OllamaService.instance.sendChat(
          modelId: resolvedModel,
          history: history,
          baseUrl: ollamaBaseUrl,
          apiKey: apiKey,
          temperature: temperature,
          numPredict: numPredict,
          numCtx: numCtx,
        );

      case LlmBackend.ollamaPython:
        final resolvedModel = (ollamaModelId != null && ollamaModelId.isNotEmpty)
            ? ollamaModelId
            : modelId;
        if (resolvedModel.isEmpty) {
          throw Exception(
              "Ollama Python bridge: no model selected. Pull one from Settings first.");
        }
        final bridgeUrl =
            (ollamaPythonBridgeUrl != null && ollamaPythonBridgeUrl.isNotEmpty)
                ? ollamaPythonBridgeUrl
                : OllamaPythonManager.defaultBridgeUrl;
        if (!await OllamaPythonManager.instance
            .isBridgeReachable(bridgeUrl: bridgeUrl)) {
          final started = await OllamaPythonManager.instance.startBridge(
            bridgeUrl: bridgeUrl,
          );
          if (!started) {
            throw Exception(
              "Failed to start the Ollama Python bridge. Open Settings, "
              "install the Python package, and start the bridge.",
            );
          }
        }
        return LocalLlmService.instance.sendChat(
          serverUrl: bridgeUrl,
          modelId: resolvedModel,
          history: history,
        );

      case LlmBackend.orchestrator:
        if (OrchestratorManager.instance.isRunning &&
            OrchestratorManager.instance.currentBackend !=
                OrchestratorBackend.huggingface) {
          await OrchestratorManager.instance.stop();
        }

        // Start orchestrator if not already running.
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

        // Orchestrator maintains its own conversation history across calls.
        // Send only the latest user turn; `new_session=true` on the first
        // message of a conversation would reset state — but since the
        // caller decides when to stop the orchestrator, we just send the
        // last user message here.
        final lastUser = _lastUserMessage(history);
        if (lastUser == null) {
          throw Exception("No user message to send.");
        }
        return OrchestratorManager.instance.sendPrompt(
          lastUser,
          sessionKey: conversationId,
          seedHistory: _seedHistoryForOrchestrator(history),
        );

      case LlmBackend.ollamaOrchestrator:
        // Resolve the Ollama model tag the same way the plain `ollama`
        // backend does — prefer an explicit per-conversation ollama model,
        // fall back to the generic modelId (which will also have been set
        // from the Ollama dropdown in Settings).
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

        // If the orchestrator is already running on the HF backend from a
        // previous session, stop it before restarting on Ollama — the
        // Python subprocess only supports one backend per lifetime.
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
          );
          if (!started) {
            throw Exception(
              "Failed to start Ollama-backed orchestrator. Check that "
              "Python is installed and the Ollama daemon is running "
              "(Settings → 🦙 Ollama → Start Ollama server). "
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
          seedHistory: _seedHistoryForOrchestrator(history),
        );

      case LlmBackend.groq:
        final settings = BackendSettingsRepository.instance;
        final groqKey = await settings.getGroqApiKey() ?? '';
        final savedModel = await settings.getGroqModel() ?? '';
        // Prefer the per-conversation model (set via the chat-header model
        // switcher).  HuggingFace model IDs contain '/' — if modelId looks
        // like one of those it means the conversation was created before the
        // Groq backend was configured, so fall back to the saved setting.
        final groqModel = (modelId.isNotEmpty && !modelId.contains('/'))
            ? modelId
            : (savedModel.isNotEmpty ? savedModel : modelId);
        final temperature = await settings.getGroqTemperature();
        final maxTokens = await settings.getGroqMaxTokens();
        return GroqService.instance.sendChat(
          apiKey: groqKey,
          modelId: groqModel,
          history: history,
          temperature: temperature,
          maxTokens: maxTokens,
        );

      case LlmBackend.groqOrchestrator:
        final settings = BackendSettingsRepository.instance;
        final groqKey = await settings.getGroqApiKey() ?? '';
        final savedModel = await settings.getGroqModel() ?? '';
        // Same preference as the plain groq case above.
        final groqModel = (modelId.isNotEmpty && !modelId.contains('/'))
            ? modelId
            : (savedModel.isNotEmpty ? savedModel : modelId);
        final temperature = await settings.getGroqTemperature();
        final maxTokens = await settings.getGroqMaxTokens();

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
          );

          // If startup failed because the `groq` Python package is missing
          // (the script exits with code 2 and prints "Missing dependency"),
          // auto-install dependencies and retry once — so the user doesn't
          // have to find the "Install Dependencies" button in Settings.
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
          seedHistory: _seedHistoryForOrchestrator(history),
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
    List<ChatMessage> history,
  ) {
    if (history.isEmpty) return const [];
    final seed = history.sublist(0, history.length - 1);
    return seed
        .map((m) => {
              'role': switch (m.role) {
                MessageRole.user => 'user',
                MessageRole.assistant => 'assistant',
                MessageRole.system => 'system',
              },
              'content': m.content,
            })
        .toList(growable: false);
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
      case LlmBackend.huggingFace:
        // Could implement a health check for HF API
        return token != null && token.isNotEmpty;

      case LlmBackend.local:
        if (localServerUrl == null || localServerUrl.isEmpty) return false;
        return LocalLlmService.instance.isServerAvailable(localServerUrl);

      case LlmBackend.orchestrator:
        // Orchestrator just needs a valid HF token
        return token != null && token.isNotEmpty;

      case LlmBackend.ollama:
        return OllamaService.instance.isServerReachable(baseUrl: ollamaBaseUrl);

      case LlmBackend.ollamaPython:
        return OllamaPythonManager.instance
            .isBridgeReachable(bridgeUrl: ollamaPythonBridgeUrl);

      case LlmBackend.ollamaOrchestrator:
        // Needs the Ollama daemon reachable; the orchestrator subprocess
        // starts on demand from `sendChat`, so we don't probe it here.
        return OllamaService.instance.isServerReachable(baseUrl: ollamaBaseUrl);

      case LlmBackend.groq:
      case LlmBackend.groqOrchestrator:
        final key = await BackendSettingsRepository.instance.getGroqApiKey();
        return key != null && key.trim().isNotEmpty;
    }
  }

  /// Stop the orchestrator if it's running
  Future<void> stopOrchestrator() async {
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }
  }
}
