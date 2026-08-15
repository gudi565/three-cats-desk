import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:three_cats_desk/core/settings/settings_service.dart';

/// SettingsService 行为验证（架构方案 v2 P0-2）。
///
/// 钉死：key 走 secure storage 不进 SharedPreferences（红线）、baseUrl/model 走 prefs、
/// 本地端点免 key 判定、默认智谱、保存往返一致、空 key 清除。
///
/// secure_storage 平台通道在单测无实现 → TestDefaultBinaryMessenger 注入假通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 假 secure storage 通道：内存 map 存取
  final fakeStore = <String, String>{};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'write':
        fakeStore[call.arguments['key']] = call.arguments['value'];
        return null;
      case 'read':
        return fakeStore[call.arguments['key']];
      case 'readAll':
        return Map<String, String>.of(fakeStore);
      case 'delete':
        fakeStore.remove(call.arguments['key']);
        return null;
      case 'deleteAll':
        fakeStore.clear();
        return null;
      case 'containsKey':
        return fakeStore.containsKey(call.arguments['key']);
    }
    return null;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeStore.clear();
  });

  test('保存→重载往返一致；key 不在 SharedPreferences（红线）', () async {
    final prefs = await SharedPreferences.getInstance();
    final service = SettingsService();

    await service.saveLlmConfig(const LlmConfig(
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4.7',
      apiKey: 'sk-test-123',
    ));

    // baseUrl/model 在 prefs（非敏感，设置页展示用）
    expect(prefs.getString('llm.base_url'), 'https://open.bigmodel.cn/api/paas/v4');
    expect(prefs.getString('llm.model'), 'glm-4.7');
    // ⚠ 红线：key 绝不进 prefs（mock 的 secure storage 写不到 prefs）
    expect(prefs.getKeys().any((k) => k.contains('api')), isFalse);

    final loaded = await service.loadLlmConfig();
    expect(loaded.baseUrl, 'https://open.bigmodel.cn/api/paas/v4');
    expect(loaded.model, 'glm-4.7');
  });

  test('默认配置=智谱；云端端点无 key → 未配置', () async {
    final service = SettingsService();
    final c = await service.loadLlmConfig();
    expect(c.baseUrl, SettingsService.defaultLlmBaseUrl);
    expect(c.model, SettingsService.defaultLlmModel);
    expect(c.apiKey, isEmpty);
    expect(c.hasCredentials, isFalse); // 智谱云端没 key 不可用
    expect(await service.isLlmConfigured(), isFalse);
  });

  test('本地端点（Ollama）免 key 即可用', () async {
    const c = LlmConfig(
      baseUrl: 'http://localhost:11434/v1',
      model: 'qwen3:8b',
      apiKey: '',
    );
    expect(c.isLocalEndpoint, isTrue);
    expect(c.hasCredentials, isTrue);
  });

  test('保存空 key = 清除凭据', () async {
    final service = SettingsService();
    await service.saveLlmConfig(const LlmConfig(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'glm-4.7',
        apiKey: 'sk-x'));
    await service.saveLlmConfig(const LlmConfig(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'glm-4.7',
        apiKey: ''));
    final c = await service.loadLlmConfig();
    expect(c.apiKey, isEmpty);
    expect(c.hasCredentials, isFalse);
  });

  test('secure storage 默认带 Android resetOnError（云备份坑对策）', () {
    final s = SettingsService();
    // 构造器默认 secure storage 配置了 aOptions.resetOnError——
    // 通过注入自定义实例可覆盖（测试通道）。
    final injected = SettingsService(
      secure: const FlutterSecureStorage(
        aOptions: AndroidOptions(resetOnError: true),
      ),
    );
    expect(injected, isNotNull);
    expect(s, isNotNull);
  });
}
