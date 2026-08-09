import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStore implements SecretStore {
  PlatformSecretStore._();
  static final PlatformSecretStore instance = PlatformSecretStore._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

abstract final class SecretKeys {
  static const apiKey = 'llm.primary_api_key';
  static const llmChain = 'llm.chain_with_secrets';
  static const oneBotToken = 'onebot.access_token';
  static const devServerToken = 'developer.rebuild_token';
}
