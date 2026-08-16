// 深度讲解模式真模型实测（ZHIPU_KEY env；无 key 跳过）
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/rag/rag_indexer.dart';
import 'package:three_cats_desk/features/agent/agent_events.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/prompts_zh.dart';
import 'package:three_cats_desk/features/agent/tool_composition.dart';
import 'package:three_cats_desk/features/agent/tools/solve_tools.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('live 深度讲解：模型走 solve_plan→…→finish_step→最终讲解', () async {
    final key = Platform.environment['ZHIPU_KEY'] ?? '';
    if (key.isEmpty) {
      // ignore: avoid_print
      print('跳过：未设置 ZHIPU_KEY');
      return;
    }
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    // 一道真实考研错题 + 考纲资料
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1', stem: '实践是检验真理的唯一标准，因为',
          optionsJson: '["实践具有直接现实性","实践是社会历史性活动","实践是有意识的能动活动","实践的形式多种多样"]',
          answerIndex: 0, explanation: Value('直接现实性：实践能把主观认识变成客观现实并加以对照')),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));
    await db.upsertNote(NotesCompanion.insert(
        id: 'syl', title: const Value('政治 · 考纲'),
        content: const Value('## 认识论\n- 实践是检验真理的唯一标准：直接现实性\n- 真理的客观性'), subject: const Value('政治')));
    final rag = RagIndexer(db);
    await rag.rebuild();

    final flags = await ToolMountFlags.detect(db, ragReady: rag.isReady);
    final composed = composeTools(db, flags: flags, intimacyOf: () => 3, rag: rag, searchFn: (_) => true);
    final solveSession = SolveSession('live-${const Uuid().v4()}');
    final tools = {...composed.tools, ...buildSolveTools(solveSession)};

    final system = PromptsZh.buildSystem(
      extraBlocks: const [(name: '用户档案', content: '他的目标：中国美术学院 美术史论（政治必考）。')],
      toolsBlock: '${composed.toolsBlock}\n- solve 三件套：按系统提示的深度讲解模式流程使用。',
      kbManifest: '[资料清单] 笔记：政治·考纲',
      loopOverride: PromptsZh.solveSystem,
    );

    final loop = AgentLoop(maxIterations: 14);
    final events = await loop.run(
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4.7',
      apiKey: key,
      systemPrompt: system,
      userMessage: '请深度讲解我最近错的那道题（实践是检验真理的唯一标准）',
      tools: tools,
    ).toList();

    final calls = events.whereType<AgentToolCall>().map((t) => t.name).toList();
    final done = events.whereType<AgentDone>();
    // ignore: avoid_print
    print('调用序列: $calls');
    // ignore: avoid_print
    print('最终讲解前600字:\n${done.isNotEmpty ? done.last.answer.substring(0, done.last.answer.length > 600 ? 600 : done.last.answer.length) : '(无)'}');

    // 脊柱铁律：走了计划（顺序允许模型先查一眼错题再计划——两次实测均完整走完脊柱）
    expect(calls, contains('solve_plan'), reason: '必须先提交计划');
    expect(calls, contains('solve_finish_step'));
    expect(solveSession.steps.first.done, isTrue); // 引擎状态真被推进
    expect(done, isNotEmpty);
    expect(done.last.answer, contains('直接现实性')); // 讲到点子上
    expect(events.whereType<AgentError>(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
