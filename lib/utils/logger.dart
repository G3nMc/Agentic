import 'package:flutter/foundation.dart';

class Logger {
  static const String _tag = 'ChatApp';
  
  static void debug(String message) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('[$_tag DEBUG] $message');
    }
  }
  
  static void info(String message) {
    // ignore: avoid_print
    print('[$_tag INFO] $message');
  }
  
  static void warn(String message) {
    // ignore: avoid_print
    print('[$_tag WARN] $message');
  }
  
  static void error(String message, [Object? error]) {
    // ignore: avoid_print
    print('[$_tag ERROR] $message${error != null ? ': $error' : ''}');

    if (error is Error && error.stackTrace != null && kDebugMode) {
      // ignore: avoid_print
      print(error.stackTrace);
    }
  }
  
  static void logChatProcessing(String conversationId, String message) {
    debug('ChatProcessing [$conversationId]: $message');
  }
  
  static void logContextSummary(String conversationId, String message) {
    debug('ContextSummary [$conversationId]: $message');
  }
  
  static void logLLMCall(String modelId, String message) {
    debug('LLMCall [$modelId]: $message');
  }
}