import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/profile/profile_notifier.dart';
import 'package:three_cats_desk/core/rag/rag_indexer.dart';
import 'package:three_cats_desk/core/settings/settings_service.dart';
import 'package:three_cats_desk/features/agent/agent_events.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/llm_client.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';
import 'package:three_cats_desk/features/cat/cat_provider.dart';

import '../../core/providers.dart';

/// 智能体会话状态（P2-3）：UI 消息流 + 运行态。
///
/// 组装全部零件：AgentLoop（P1-1）+ 五猫工具（P1-2）+ LlmConfig（P0-2）+
/// 对话持久化（P2-1）+ BM25（P2-2）。catProvider 亲密度与 contentProfile
/// 院校/专业注入系统提示词——"认识他和他的资料"。
class ChatMessageUi {
  final String role; // user / assistant
  final String text;
  final List<String> toolTrace; // 工具调用轨迹（assistant 消息的折叠行）
  const ChatMessageUi({required this.role, required this.text, this.toolTrace = const []});
}

class AgentChatState {
  final List<ChatMessageUi> messages;
  final bool running; // 循环执行中
  final String? error; // 可读错误（UI 横幅）
  final bool llmReady; // LLM 已配置（未配置→引导设置）
  const AgentChatState({
    this.messages = const [],
    this.running = false,
    this.error,
    this.llmReady = false,
  });
}

/// LLM client 单例（测试 override 注入 mock）。
final llmClientProvider = Provider<LlmClient>((ref) => LlmClient());

class AgentChatNotifier extends StateNotifier<AgentChatState> {
  final Ref ref;
  late final AgentLoop _loop;
  static const _uuid = Uuid();
  String? _sessionId;

  AgentChatNotifier(this.ref) : super(const AgentChatState()) {
    _loop = AgentLoop(llm: ref.read(llmClientProvider));
    _init();
  }

  Future<void> _init() async {
    final cfg = await ref.read(settingsServiceProvider).loadLlmConfig();
    // 恢复历史会话（续聊）
    final db = ref.read(appDatabaseProvider);
    final sid = await db.latestSessionId();
    List<ChatMessageUi> history = const [];
    if (sid != null) {
      _sessionId = sid;
      final msgs = await db.getChatMessages(sid);
      history = [
        for (final m in msgs)
          if (m.role == 'user' || m.role == 'assistant')
            ChatMessageUi(role: m.role, text: m.content)
      ];
    }
    state = AgentChatState(messages: history, llmReady: cfg.hasCredentials);
  }

  /// 刷新 LLM 配置态（设置页保存后调用）。
  Future<void> refreshLlmReady() async {
    final cfg = await ref.read(settingsServiceProvider).loadLlmConfig();
    state = AgentChatState(
        messages: state.messages, llmReady: cfg.hasCredentials);
  }

  /// 发送一条消息：跑 agent 循环，事件流驱动 UI + 持久化。
  Future<void> send(String text) async {
    if (state.running || text.trim().isEmpty) return;
    final cfg = await ref.read(settingsServiceProvider).loadLlmConfig();
    if (!cfg.hasCredentials) {
      state = AgentChatState(
          messages: state.messages, llmReady: false, error: '请先配置模型（右下角设置）');
      return;
    }
    _sessionId ??= 'chat-${_uuid.v4()}';
    final db = ref.read(appDatabaseProvider);

    state = AgentChatState(
      messages: [
        ...state.messages,
        ChatMessageUi(role: 'user', text: text.trim()),
        const ChatMessageUi(role: 'assistant', text: ''), // 运行中气泡（占位，逐步更新）
      ],
      running: true,
      llmReady: true,
    );
    await db.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'msg-${_uuid.v4()}',
        sessionId: _sessionId!,
        role: 'user',
        content: text.trim()));

    // 系统提示词：猫人设 + 考研语境 + 他的档案（认识他）
    final cat = ref.read(catProvider);
    final profile = ref.read(contentProfileProvider);
    final systemPrompt = [
      '你是「三猫书桌」的考研陪伴智能体，亲切、简洁、说人话，像一只懂考研的猫。',
      '你认识这位用户，可以调用工具查看他的真实数据（错题、进度、知识库），回答要基于工具结果，不要编造。',
      if (profile.suggestSchool.isNotEmpty)
        '他的目标：${profile.suggestSchool} ${profile.suggestMajor}。',
      '当前资料包：${profile.displayName}。',
      '猫亲密度 ${cat.intimacy}（他复习/专注越多越高）。',
      '回答用中文，先给结论再展开；讲错题时给出正确答案和解析；鼓励但不啰嗦。',
    ].join('\n');

    // 工具集：五猫数据 + BM25 知识库（先确保索引就绪）
    final rag = ref.read(ragIndexProvider);
    if (!rag.isReady) await rag.rebuild();
    final tools = buildCatTools(db,
        intimacyOf: () => ref.read(catProvider).intimacy, rag: rag);

    // 历史（最近 12 条，控上下文）
    final history = [
      for (final m in state.messages.length > 13
          ? state.messages.sublist(state.messages.length - 13, state.messages.length - 1)
          : state.messages.sublist(0, state.messages.length - 1))
        {'role': m.role, 'content': m.text}
    ];

    final trace = <String>[];
    final buf = StringBuffer();
    await for (final ev in _loop.run(
      baseUrl: cfg.baseUrl,
      model: cfg.model,
      apiKey: cfg.apiKey,
      systemPrompt: systemPrompt,
      userMessage: text.trim(),
      tools: tools,
      history: history,
    )) {
      switch (ev) {
        case AgentText(:final text):
          buf.write(text);
          _patchRunning(trace, buf.toString());
        case AgentToolCall(:final name):
          trace.add('🔧 $name');
          _patchRunning(trace, buf.toString());
        case AgentToolResult(:final name):
          trace.removeLast(); // 折叠为已完成
          trace.add('✅ $name');
          _patchRunning(trace, buf.toString());
        case AgentDone(:final answer):
          buf.clear();
          buf.write(answer);
        case AgentError(:final message):
          state = AgentChatState(
            messages: state.messages,
            running: false,
            error: message,
            llmReady: true,
          );
          return;
        default:
          break; // TurnStart/Log 不驱动 UI
      }
    }

    // 完成：更新最后一条气泡（运行中→定稿），不再 append
    final answer = buf.toString();
    state = AgentChatState(
      messages: [
        ...state.messages.sublist(0, state.messages.length - 1),
        ChatMessageUi(role: 'assistant', text: answer, toolTrace: List.of(trace)),
      ],
      running: false,
      llmReady: true,
    );
    await db.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'msg-${_uuid.v4()}',
        sessionId: _sessionId!,
        role: 'assistant',
        content: answer,
        eventsJson: Value(jsonEncode(trace))));
  }

  void _patchRunning(List<String> trace, String partial) {
    // 更新最后一条（运行中气泡），不 append
    state = AgentChatState(
      messages: [
        ...state.messages.sublist(0, state.messages.length - 1),
        ChatMessageUi(role: 'assistant', text: partial, toolTrace: List.of(trace)),
      ],
      running: true,
      llmReady: true,
    );
  }

  void clearError() {
    state = AgentChatState(
        messages: state.messages, running: state.running, llmReady: state.llmReady);
  }
}

final agentChatProvider =
    StateNotifierProvider.autoDispose<AgentChatNotifier, AgentChatState>((ref) {
  return AgentChatNotifier(ref);
});
