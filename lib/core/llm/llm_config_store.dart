import 'dart:convert';

import '../../models/llm_provider.dart';
import '../../services/database_service.dart';
import '../storage/secret_store.dart';

class LlmConfigStore {
  LlmConfigStore({SecretStore? secrets})
      : _secrets = secrets ?? PlatformSecretStore.instance;

  final SecretStore _secrets;

  Future<String> primaryKey() async =>
      await _secrets.read(SecretKeys.apiKey) ?? '';

  Future<LlmChainConfig?> loadChain() async {
    final secureRaw = await _secrets.read(SecretKeys.llmChain);
    final cfg = await DB.getConfig();
    final raw = secureRaw?.isNotEmpty == true ? secureRaw : cfg['llm_chain'];
    if (raw == null || raw.isEmpty) return null;
    try {
      return LlmChainConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save({required LlmChainConfig chain, String? primaryKey}) async {
    final fullJson = jsonEncode(chain.toJson());
    await _secrets.write(SecretKeys.llmChain, fullJson);
    if (primaryKey != null && primaryKey.isNotEmpty) {
      await _secrets.write(SecretKeys.apiKey, primaryKey);
    }

    final sanitized = chain.copyWith(
      slots: chain.slots.map((slot) => slot.copyWith(apiKey: '')).toList(),
    );
    await DB.setConfig('llm_chain', jsonEncode(sanitized.toJson()));
    await DB.setConfig('api_key', '');
    final primary = chain.activeSlot;
    if (primary != null) {
      final vendor = findVendor(primary.vendorId);
      final baseUrl = primary.customUrl?.isNotEmpty == true
          ? primary.customUrl!
          : (vendor?.defaultUrl ?? 'https://api.deepseek.com/v1');
      await DB.setConfig('base_url', baseUrl);
      await DB.setConfig('model', primary.modelId);
    }
  }

  Future<void> migrateLegacySecrets() async {
    final cfg = await DB.getConfig();
    final legacyKey = cfg['api_key'] ?? '';
    final legacyChain = cfg['llm_chain'] ?? '';

    if (legacyKey.isNotEmpty && await _secrets.read(SecretKeys.apiKey) == null) {
      await _secrets.write(SecretKeys.apiKey, legacyKey);
    }
    if (legacyChain.isNotEmpty && await _secrets.read(SecretKeys.llmChain) == null) {
      await _secrets.write(SecretKeys.llmChain, legacyChain);
    }

    if (legacyChain.isNotEmpty) {
      try {
        final chain = LlmChainConfig.fromJson(
          jsonDecode(legacyChain) as Map<String, dynamic>,
        );
        final sanitized = chain.copyWith(
          slots: chain.slots.map((slot) => slot.copyWith(apiKey: '')).toList(),
        );
        await DB.setConfig('llm_chain', jsonEncode(sanitized.toJson()));
      } catch (_) {
        // Keep malformed non-secret configuration for the settings UI to repair.
      }
    }
    if (legacyKey.isNotEmpty) await DB.setConfig('api_key', '');
  }
}
