import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置/密钥统一收口（架构方案 v2 P0-2，2026-08-15）。
///
/// 职责边界（按生命周期分存，深研结论 3-0）：
///   - LLM API key → flutter_secure_storage（OS 钥匙串/DPAPI/Keystore），
///     绝不进 SharedPreferences/备份/.smpack。
///   - LLM baseUrl/model + 其余偏好 → SharedPreferences（非敏感）。
///
/// Android 云备份坑对策（深研高置信）：Google Drive 默认自动备份会把 secure-storage
/// 密文恢复到新设备但 Keystore 密钥不可迁移 → InvalidKeyException。
/// 对策 = `resetOnError: true`（恢复后检测到解不开即清掉该条，用户重填 key，
/// 损失仅限"重新粘贴一次 key"，不崩 App、不破其它数据）。
///
/// LLM 配置默认智谱（国内直连便宜），baseUrl 指向任意 OpenAI 兼容端点即可切
/// Ollama(http://localhost:11434/v1)/LM Studio/DeepSeek——同一个 client 通吃。
class SettingsService {
  static const _kLlmBaseUrl = 'llm.base_url';
  static const _kLlmModel = 'llm.model';
  static const _secureKeyApiKey = 'llm.api_key';

  /// 智谱默认（OpenAI 兼容）。用户可在设置里改。
  static const defaultLlmBaseUrl = 'https://open.bigmodel.cn/api/paas/v4';
  static const defaultLlmModel = 'glm-4.7';

  final FlutterSecureStorage _secure;

  SettingsService({FlutterSecureStorage? secure})
      : _secure = secure ??
            const FlutterSecureStorage(
              // Android 云备份恢复后密钥不可解 → 清条目重填，不崩。
              aOptions: AndroidOptions(resetOnError: true),
            );

  /// 当前 LLM 配置（key 为空 = 未配置，UI 引导填写）。
  Future<LlmConfig> loadLlmConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final apiKey = await _secure.read(key: _secureKeyApiKey) ?? '';
    return LlmConfig(
      baseUrl: prefs.getString(_kLlmBaseUrl) ?? defaultLlmBaseUrl,
      model: prefs.getString(_kLlmModel) ?? defaultLlmModel,
      apiKey: apiKey,
    );
  }

  /// 保存 LLM 配置。apiKey 走 secure storage；baseUrl/model 走 prefs。
  Future<void> saveLlmConfig(LlmConfig c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLlmBaseUrl, c.baseUrl);
    await prefs.setString(_kLlmModel, c.model);
    if (c.apiKey.isEmpty) {
      await _secure.delete(key: _secureKeyApiKey);
    } else {
      await _secure.write(key: _secureKeyApiKey, value: c.apiKey);
    }
  }

  /// 是否已配置可用（有 key 才算，Ollama 本地无 key 场景由 baseUrl 判定）。
  Future<bool> isLlmConfigured() async {
    final c = await loadLlmConfig();
    return c.hasCredentials;
  }
}

/// LLM 连接配置。baseUrl/model 非敏感可入设置页明文展示；apiKey 仅内存传递。
class LlmConfig {
  final String baseUrl;
  final String model;
  final String apiKey;

  const LlmConfig({
    required this.baseUrl,
    required this.model,
    required this.apiKey,
  });

  /// 本地模型端点（Ollama/LM Studio 等）通常无需 key。
  bool get isLocalEndpoint =>
      baseUrl.contains('localhost') || baseUrl.contains('127.0.0.1');

  /// 有无可用凭据：本地端点免 key，云端端点须有 key。
  bool get hasCredentials => isLocalEndpoint || apiKey.isNotEmpty;

  LlmConfig copyWith({String? baseUrl, String? model, String? apiKey}) =>
      LlmConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );
}

/// 全局单例 provider。
final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService();
});

/// LLM 配置状态（设置页/智能体屏 watch；保存后自增刷新）。
final llmConfigProvider =
    StateNotifierProvider<LlmConfigNotifier, AsyncValue<LlmConfig>>((ref) {
  return LlmConfigNotifier(ref.watch(settingsServiceProvider));
});

class LlmConfigNotifier extends StateNotifier<AsyncValue<LlmConfig>> {
  final SettingsService _service;
  LlmConfigNotifier(this._service) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      state = AsyncValue.data(await _service.loadLlmConfig());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> save(LlmConfig c) async {
    await _service.saveLlmConfig(c);
    state = AsyncValue.data(c);
  }

  Future<void> reload() => _load();
}
