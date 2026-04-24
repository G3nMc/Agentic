class ApiConstants {
  ApiConstants._();

  // Hugging Face router endpoint used by HF.html reference client.
  static const String hfRouterBaseUrl = "https://router.huggingface.co";
  static const String chatCompletionsPath = "/v1/chat/completions";

  // Default model preloaded on first run (same as HF.html).
  static const String defaultModelId = "Qwen/Qwen3-Coder-480B-A35B-Instruct:hyperbolic";

  // Request timeouts.
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(minutes: 5);
}
