import 'dart:io';

import 'package:dio/dio.dart';

import '../data/models/local_server_config.dart';

class LocalServerManager {
  LocalServerManager._();

  static final LocalServerManager instance = LocalServerManager._();

  final Map<String, Process> _runningServers = {};
  final Dio _dio = Dio();

  /// Start a local server from Python code
  /// Returns the server URL if successful
  Future<String> startServer(LocalServerConfig config) async {
    // Check if already running
    if (_runningServers.containsKey(config.modelId)) {
      return config.getServerUrl();
    }

    try {
      // Create temporary Python file
      final tempDir = Directory.systemTemp;
      final pythonFile = File('${tempDir.path}/hf_chat_server_${config.modelId}.py');
      await pythonFile.writeAsString(config.pythonCode);

      // Start Python process
      final process = await Process.start(
        'python',
        [pythonFile.path],
        mode: ProcessStartMode.detached,
      );

      _runningServers[config.modelId] = process;

      // Wait for server to be ready (max 30 seconds)
      await _waitForServer(config.getServerUrl(), maxAttempts: 30);

      return config.getServerUrl();
    } catch (e) {
      _runningServers.remove(config.modelId);
      throw Exception("Failed to start server: $e");
    }
  }

  /// Stop a running server
  Future<void> stopServer(String modelId) async {
    final process = _runningServers[modelId];
    if (process != null) {
      process.kill();
      _runningServers.remove(modelId);
    }
  }

  /// Stop all running servers
  Future<void> stopAllServers() async {
    for (final process in _runningServers.values) {
      process.kill();
    }
    _runningServers.clear();
  }

  /// Check if a server is running
  bool isServerRunning(String modelId) {
    return _runningServers.containsKey(modelId);
  }

  /// Get list of running servers
  List<String> getRunningServers() {
    return _runningServers.keys.toList();
  }

  /// Wait for server to respond to health check
  Future<void> _waitForServer(String serverUrl, {int maxAttempts = 30}) async {
    int attempts = 0;
    while (attempts < maxAttempts) {
      try {
        final response = await _dio.get(
          "$serverUrl/health",
          options: Options(receiveTimeout: const Duration(seconds: 2)),
        );
        if (response.statusCode == 200) {
          return; // Server is ready
        }
      } catch (e) {
        // Server not ready yet
      }
      attempts++;
      await Future.delayed(const Duration(seconds: 1));
    }
    throw Exception("Server did not start within timeout");
  }
}
