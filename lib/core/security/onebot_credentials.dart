import 'dart:convert';
import 'dart:math';

import '../storage/secret_store.dart';

class OneBotCredentials {
  OneBotCredentials({SecretStore? secrets})
      : _secrets = secrets ?? PlatformSecretStore.instance;

  final SecretStore _secrets;

  Future<String> loadOrCreateToken() async {
    final existing = await _secrets.read(SecretKeys.oneBotToken);
    if (existing != null && existing.length >= 32) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final token = base64UrlEncode(bytes).replaceAll('=', '');
    await _secrets.write(SecretKeys.oneBotToken, token);
    return token;
  }

  Future<String> rotateToken() async {
    await _secrets.delete(SecretKeys.oneBotToken);
    return loadOrCreateToken();
  }
}
