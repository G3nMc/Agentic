import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  SecureStorageService._() {
    _storage = const FlutterSecureStorage();
  }

  static final SecureStorageService instance = SecureStorageService._();

  late final FlutterSecureStorage _storage;

  static const String _keyHfToken = 'hf_api_token';
  static const String _keyModelId = 'hf_model_id';

  /// Saves the Hugging Face API token securely
  Future<void> saveToken(String token) async {
    await _storage.write(key: _keyHfToken, value: token);
  }

  /// Retrieves the Hugging Face API token
  Future<String?> getToken() async {
    return await _storage.read(key: _keyHfToken);
  }

  /// Saves the preferred Model ID securely
  Future<void> saveModelId(String modelId) async {
    await _storage.write(key: _keyModelId, value: modelId);
  }

  /// Retrieves the preferred Model ID
  Future<String?> getModelId() async {
    return await _storage.read(key: _keyModelId);
  }

  /// Deletes the token from storage (Logout/Reset)
  Future<void> deleteToken() async {
    await _storage.delete(key: _keyHfToken);
  }

  /// Clears all stored settings
  Future<void> clearAll() async {
    await _storage.deleteAll();
  }
}