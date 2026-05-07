class ApiConstants {
  ApiConstants._();

  // ---------------------------------------------------------------------------
  // Hugging Face
  // ---------------------------------------------------------------------------
  /// Hugging Face router endpoint used by the HF.html reference client.
  static const String hfRouterBaseUrl = "https://router.huggingface.co";
  static const String chatCompletionsPath = "/v1/chat/completions";
  static const String huggingfaceTokensUrl =
      "https://huggingface.co/settings/tokens";

  // ---------------------------------------------------------------------------
  // Groq
  // ---------------------------------------------------------------------------
  static const String groqBaseUrl = "https://api.groq.com/openai/v1";

  // ---------------------------------------------------------------------------
  // OpenRouter
  // ---------------------------------------------------------------------------
  static const String openRouterBaseUrl = "https://openrouter.ai/api/v1";

  // ---------------------------------------------------------------------------
  // GitHub Models
  // ---------------------------------------------------------------------------
  /// Base URL for GitHub Models inference + catalog APIs.
  static const String githubModelsBaseUrl = "https://models.github.ai";

  /// Catalog (model listing) endpoint.
  static const String githubModelsCatalogPath = "/catalog/models";

  /// Inference (chat completions) endpoint — OpenAI-compatible.
  static const String githubModelsChatCompletionsPath =
      "/inference/chat/completions";

  /// Required `X-GitHub-Api-Version` header value.
  static const String githubModelsApiVersion = "2026-03-10";

  /// Where users create a fine-grained PAT with `models:read` scope.
  static const String githubModelsTokensUrl =
      "https://github.com/settings/personal-access-tokens/new";

  // ---------------------------------------------------------------------------
  // Ollama
  // ---------------------------------------------------------------------------
  /// Local Ollama daemon address (native REST API).
  static const String ollamaLocalBaseUrl = "http://localhost:11434";

  /// Local Python bridge for Ollama (started by the bundled helper).
  static const String ollamaPythonBridgeUrl = "http://127.0.0.1:11501";

  /// Ollama Cloud (hosted) endpoint — requires Bearer token.
  static const String ollamaCloudBaseUrl = "https://ollama.com";

  /// Public Ollama download page.
  static const String ollamaDownloadUrl = "https://ollama.com/download";

  // ---------------------------------------------------------------------------
  // Request timeouts
  // ---------------------------------------------------------------------------
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(minutes: 15);
}
