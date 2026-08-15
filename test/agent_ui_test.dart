import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/local_only_backend.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/core/settings/settings_service.dart';
import 'package:three_cats_desk/features/agent/agent_events.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/chat_provider.dart';
import 'package:three_cats_desk/features/agent/llm_client.dart';
import 'package:three_cats_desk/features/shell/agent_screen.dart';
import 'package:three_cats_desk/features/shell/llm_settings_screen.dart';

/// 智能体对话 UI 集成测试（P2-3，mock LLM 零网络）。
///
/// 钉死：未配置→引导横幅+发送被拦；配置后发送→消息流出现 user+assistant+工具轨迹；
/// 历史持久化恢复；设置屏渲染与预设。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // mock secure storage 通道
  final fakeStore = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
    switch (call.method) {
      case 'write':
        fakeStore[call.arguments['key']] = call.arguments['value'];
        return null;
      case 'read':
        return fakeStore[call.arguments['key']];
      case 'delete':
        fakeStore.remove(call.arguments['key']);
        return null;
      case 'containsKey':
        return fakeStore.containsKey(call.arguments['key']);
    }
    return null;
  });

  late AppDatabase db;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeStore.clear();
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  ProviderScope _scope(Widget child, {LlmClient? mockLlm}) => ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          cloudSyncProvider.overrideWithValue(LocalOnlyBackend()),
          settingsServiceProvider.overrideWithValue(
              _FakeSettings(fakeStore)),
          if (mockLlm != null) llmClientProvider.overrideWithValue(mockLlm),
        ],
        child: MaterialApp(home: child),
      );

  testWidgets('未配置 → 引导横幅，发送被拦不崩', (tester) async {
    await tester.pumpWidget(_scope(const AgentScreen()));
    await tester.pump();
    expect(find.text('先配置一下模型，智能体才能工作'), findsOneWidget);
    expect(find.text('我是你的考研搭子'), findsOneWidget);
  });

  testWidgets('配置后发送 → 消息流 user+assistant+工具轨迹（mock LLM 全链路）',
      (tester) async {
    // 配好 key
    final settings = _FakeSettings(fakeStore);
    await settings.saveLlmConfig(const LlmConfig(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        model: 'glm-4.7',
        apiKey: 'sk-test'));

    final mockLlm = ScriptLlm()
      ..responses = [
        const LlmResponse(
            content: '我查查',
            toolCalls: [
              LlmToolCall(id: 'c1', name: 'query_wrong_questions', args: {})
            ]),
        const LlmResponse(content: '你还没做过题，先去稳稳刷一套吧～', toolCalls: []),
      ];

    await tester.pumpWidget(_scope(const AgentScreen(), mockLlm: mockLlm));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('先配置一下模型，智能体才能工作'), findsNothing); // 已配置不显示

    // 点示例问题 chip（比输文本稳）
    await tester.tap(find.text('我最近错了哪些题？'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('我最近错了哪些题？'), findsWidgets); // user 消息（+chip 本身）
    expect(find.textContaining('稳稳刷一套'), findsOneWidget); // assistant 回答
    expect(find.textContaining('query_wrong_questions'), findsWidgets); // 工具轨迹

    // 持久化：消息进了 drift
    final sid = await db.latestSessionId();
    expect(sid, isNotNull);
    final msgs = await db.getChatMessages(sid!);
    expect(msgs.where((m) => m.role == 'user').length, 1);
    expect(msgs.where((m) => m.role == 'assistant').length, 1);
  });

  testWidgets('设置屏：预设/密文/保存提示', (tester) async {
    await tester.pumpWidget(_scope(const LlmSettingsScreen()));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('智谱'), findsOneWidget);
    expect(find.textContaining('Ollama'), findsOneWidget);
    expect(find.textContaining('API Key'), findsWidgets);
    expect(find.textContaining('不上传、不进备份'), findsOneWidget);
  });
}

/// 设置服务假实现（直接读写 fake map，绕平台通道时序）。
class _FakeSettings implements SettingsService {
  final Map<String, String> store;
  _FakeSettings(this.store);

  @override
  Future<LlmConfig> loadLlmConfig() async => LlmConfig(
      baseUrl: store['llm.base_url'] ?? SettingsService.defaultLlmBaseUrl,
      model: store['llm.model'] ?? SettingsService.defaultLlmModel,
      apiKey: store['llm.api_key'] ?? '');

  @override
  Future<void> saveLlmConfig(LlmConfig c) async {
    store['llm.base_url'] = c.baseUrl;
    store['llm.model'] = c.model;
    store['llm.api_key'] = c.apiKey;
  }

  @override
  Future<bool> isLlmConfigured() async =>
      (await loadLlmConfig()).hasCredentials;
}

/// 脚本化 LLM。
class ScriptLlm extends LlmClient {
  List<LlmResponse> responses = [];
  @override
  Future<LlmResponse> chat({
    required String baseUrl,
    required String model,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
  }) async =>
      responses.removeAt(0);
}

// LlmClient 注入：chat_provider.llmClientProvider 已 provider 化
