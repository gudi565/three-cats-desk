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
import 'package:three_cats_desk/features/agent/prompts_zh.dart';
import 'package:three_cats_desk/features/agent/tool_composition.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';
import 'package:three_cats_desk/features/agent/tools/solve_tools.dart';
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
  ///
  /// [deepExplain] 深度讲解模式：注入 solve 三件套（计划-逐步-重规划脊柱）+
  /// [PromptsZh.solveSystem] 系统提示——错题讲解走这条路（DeepTutor solve 同款）。
  Future<void> send(String text, {bool deepExplain = false}) async {
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
        ChatMessageUi(role: 'user', text: deepExplain ? '深度讲解：${text.trim()}' : text.trim()),
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

    // ── DT2/DT3/DT4：分块 system + 条件工具挂载 + KB 预检索种子（DeepTutor 同款架构）──
    final cat = ref.read(catProvider);
    final profile = ref.read(contentProfileProvider);

    // 工具条件挂载：空数据不挂（工具面小=本地弱模型选择准）
    final rag = ref.read(ragIndexProvider);
    if (!rag.isReady) await rag.rebuild();
    final flags = await ToolMountFlags.detect(db, ragReady: rag.isReady);
    final composed = composeTools(
      db,
      flags: flags,
      intimacyOf: () => ref.read(catProvider).intimacy,
      rag: rag,
      searchFn: (_) => true, // 仅判定可挂载；真检索在工具内部
    );

    // [资料清单] 权威块（元数据问题以此为准）
    final kbManifest = flags.hasKb || true
        ? await _buildKbManifest(db)
        : '';

    // 深度讲解模式：追加 solve 三件套（引擎状态机保证"先计划、不跳步、有界重规划"）
    final tools = {...composed.tools};
    if (deepExplain) {
      final solveSession = SolveSession('solve-${_uuid.v4()}');
      tools.addAll(buildSolveTools(solveSession));
    }

    // 画像注入：读 scope+preferences 槽拼进用户档案块（智能体认识他）
    final memScope = await db.getMemories('scope');
    final memPrefs = await db.getMemories('preferences');
    final memBlock = [
      if (memScope.isNotEmpty)
        '掌握度（基于他的做题行为）：\n${memScope.map((m) => '- ${m.body}').join('\n')}',
      if (memPrefs.isNotEmpty)
        '他的偏好：\n${memPrefs.map((m) => '- ${m.body}').join('\n')}',
    ].join('\n');

    // 深度讲解门控（Bokosmaty 门控规则落地）：已掌握知识点只讲差异步骤，
    // 未掌握的定理+步骤全讲（专长逆转：冗余讲解对熟手有害 ηp²=0.34）。
    final gatingBlock = memScope.isEmpty
        ? ''
        : '讲解详略门控（按掌握度）：\n$memBlock\n'
            '已掌握的知识点：省略定理解释，只讲本题关键步骤；'
            '练习中/未掌握的：定理+步骤完整讲。';

    // 分块 system（DeepTutor 块序：身份/运行规则/档案/循环/资料清单/工具/语言）。
    // 深度讲解模式：循环块换成 [深度讲解模式] 全文 + solve 工具行。
    final systemPrompt = deepExplain
        ? PromptsZh.buildSystem(
            extraBlocks: [
              (
                name: '用户档案',
                content: [
                  if (profile.suggestSchool.isNotEmpty)
                    '他的目标：${profile.suggestSchool} ${profile.suggestMajor}。',
                  '当前资料包：${profile.displayName}。',
                  if (memBlock.isNotEmpty) memBlock,
                ].join('\n'),
              ),
              if (gatingBlock.isNotEmpty)
                (name: '讲解详略门控', content: gatingBlock),
            ],
            toolsBlock: '${composed.toolsBlock}\n'
                '- `solve_plan` / `solve_finish_step` / `solve_replan` — 讲解脊柱三件套（按系统提示的深度讲解模式流程使用）。',
            kbManifest: kbManifest,
            loopOverride: PromptsZh.solveSystem,
          )
        : PromptsZh.buildSystem(
            extraBlocks: [
              (
                name: '用户档案',
                content: [
                  if (profile.suggestSchool.isNotEmpty)
                    '他的目标：${profile.suggestSchool} ${profile.suggestMajor}。',
                  '当前资料包：${profile.displayName}。',
                  '猫亲密度 ${cat.intimacy}（他复习/专注越多越高）。',
                  if (memBlock.isNotEmpty) memBlock,
                  '回答先给结论再展开；讲错题时给出正确答案和解析；鼓励但不啰嗦。',
                ].join('\n'),
              ),
            ],
            toolsBlock: composed.toolsBlock,
            kbManifest: kbManifest,
          );

    // KB 预检索种子：拼 user 消息尾（不进 system——保 system 全轮字节稳定）
    var finalUserMessage = text.trim();
    if (rag.isReady) {
      final hits = rag.search(text.trim(), topK: 3);
      if (hits.isNotEmpty) {
        final seed = hits.map((h) => '- ${h.$1}').join('\n');
        finalUserMessage =
            '$finalUserMessage\n\n${PromptsZh.kbSeedHeader}\n$seed';
      }
    }

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
      userMessage: finalUserMessage,
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

  /// [资料清单] 权威块：截断的清单（限 20 条）+ 权威规则（DeepTutor manifest 同款）。
  Future<String> _buildKbManifest(AppDatabase db) async {
    final tool = ListKbDocsTool(db);
    final raw = await tool.execute(const {'limit': 20});
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final docs = (data['docs'] as List).cast<Map<String, dynamic>>();
    final lines = [
      for (final d in docs)
        '- ${d['source']}：${d['name']}${d['count'] != null ? '（${d['count']}）' : ''}',
    ].join('\n');
    final omitted = (data['omitted'] as num?)?.toInt() ?? 0;
    return [
      PromptsZh.kbManifestHeader,
      '共 ${data['total']} 个条目：',
      lines,
      if (omitted > 0) '另有 $omitted 个未列出，可用 list_kb_docs 查看完整清单',
      PromptsZh.kbManifestAuthority,
    ].join('\n');
  }
}

final agentChatProvider =
    StateNotifierProvider.autoDispose<AgentChatNotifier, AgentChatState>((ref) {
  return AgentChatNotifier(ref);
});
