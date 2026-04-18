import '../data/models/message.dart';
import 'huggingface_service.dart';
import 'local_llm_service.dart';
import 'orchestrator_manager.dart';
// ChatMessage.role is a MessageRole enum, not a String — imported above.

enum LlmBackend { huggingFace, local, orchestrator }

class LlmService {
  LlmService._();

  static final LlmService instance = LlmService._();

  /// Unified interface to send chat using either remote or local backend
  Future<String> sendChat({
    required LlmBackend backend,
    required String token, // HF token (ignored for local/orchestrator)
    required String modelId,
    required List<ChatMessage> history,
    String? localServerUrl, // e.g., "http://localhost:5000"
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

      case LlmBackend.orchestrator:
        // Start orchestrator if not already running
        if (!OrchestratorManager.instance.isRunning) {
          final started = await OrchestratorManager.instance.start(
            hfToken: token,
            modelId: modelId,
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
        return OrchestratorManager.instance.sendPrompt(lastUser);
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

  /// Check backend availability
  Future<bool> checkAvailability({
    required LlmBackend backend,
    String? token,
    String? localServerUrl,
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
    }
  }

  /// Stop the orchestrator if it's running
  Future<void> stopOrchestrator() async {
    if (OrchestratorManager.instance.isRunning) {
      await OrchestratorManager.instance.stop();
    }
  }
}
