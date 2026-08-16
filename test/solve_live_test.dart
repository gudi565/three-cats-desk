// 真模型验证深度讲解模式（手动跑，ZHIPU_KEY env）
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/agent_events.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/prompts_zh.dart';
import 'package:three_cats_desk/features/agent/tool_composition.dart';
import 'package:three_cats_desk/features/agent/tools/solve_tools.dart';

void main() {
  test('live 深度讲解：模型遵守 solve 脊柱（先 plan→逐步 finish）', () async {
    final key = Platform.environment['ZHIPU_KEY'] ?? '';
    if (key.isEmpty) { print('跳过：无 ZHIPU_KEY'); return; }
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1', stem: '对立统一规律是唯物辩证法的',
          optionsJson: '["实质与核心","次要规律","外在形式","数量关系"]',
          answerIndex: 0, explanation: Value('矛盾规律是核心')),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));

    final composed = composeTools(db,
        flags: const ToolMountFlags(hasWrongQuestions: true, hasKb: false, hasNotes: false),
        intimacyOf: () => 5);
    final solve = SolveSession('live');
    final tools = {...composed.tools, ...buildSolveTools(solve)};
    final system = PromptsZh.buildSystem(
      toolsBlock: '${composed.toolsBlock}\n- solve 三件套（见下方循环指令）',
      kbManifest: '', loopOverride: PromptsZh.solveSystem);

    final events = await AgentLoop(maxIterations: 10).run(
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4.7', apiKey: key,
      systemPrompt: system,
      userMessage: '带我一步步弄懂我最近错的那道题',
      tools: tools,
    ).toList();

    final calls = events.whereType<AgentToolCall>().map((t) => t.name).toList();
    print('工具调用序列: $calls');
    final done = events.whereType<AgentDone>();
    print('最终回答前300字: ${done.isNotEmpty ? done.last.answer.substring(0, done.last.answer.length.clamp(0, 300)) : "(无)"}');
    print('solve 状态: steps=${solve.steps.map((s) => '${s.id}${s.done ? "✓" : "·"}').toList()} replans=${solve.replans}');

    // 脊柱断言：plan 必须在 finish 之前出现（模型可能先查错题再计划——合理）
    expect(calls.indexOf('solve_plan'), lessThan(calls.indexOf('solve_finish_step')));
    expect(calls, contains('solve_finish_step'));
    expect(solve.steps, isNotEmpty);
    expect(solve.steps.any((s) => s.done), isTrue);
    expect(done, isNotEmpty);
    expect(done.last.answer, contains('实质与核心')); // 讲解引用正确答案
    expect(events.whereType<AgentError>(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
