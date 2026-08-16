// 真模型验证 DT 新架构（本地手动跑，ZHIPU_KEY env；无 key 自动跳过）
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

void main() {
  test('live DT 新架构真模型：分块system+条件挂载+清单+语言指令', () async {
    final key = Platform.environment['ZHIPU_KEY'] ?? '';
    if (key.isEmpty) {
      // ignore: avoid_print
      print('跳过：未设置 ZHIPU_KEY');
      return;
    }
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    // 造数据：错题 + 词书 + 考纲
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1', stem: '实践是检验真理的唯一标准，因为',
          optionsJson: '["实践具有直接现实性","实践是社会活动","实践有能动性","实践形式多样"]',
          answerIndex: 0, explanation: Value('直接现实性是关键')),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));
    await db.upsertDeck(LocalDecksCompanion.insert(
        id: 'd1', name: '中国画论', contentHash: const Value('h1'), cardCount: const Value(2)));
    await db.upsertNote(NotesCompanion.insert(
        id: 'syl', title: const Value('美术考研 · 考纲'),
        content: const Value('## 中国画论\n- 谢赫六法：气韵生动为首'), subject: const Value('美术')));

    final composed = composeTools(db,
        flags: const ToolMountFlags(hasWrongQuestions: true, hasKb: false, hasNotes: true),
        intimacyOf: () => 7);
    final system = PromptsZh.buildSystem(
      extraBlocks: [(name: '用户档案', content: '他的目标：中国美术学院 美术史论。')],
      toolsBlock: composed.toolsBlock,
      kbManifest: '[资料清单]（演示）词书：中国画论；题库：政治 1 题',
    );
    // ignore: avoid_print
    print('=== system 前两块预览 ===\n${system.substring(0, 200)}...');

    final loop = AgentLoop();
    final events = await loop.run(
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      model: 'glm-4.7',
      apiKey: key,
      systemPrompt: system,
      userMessage: '我知识库里都有什么资料？顺便告诉我我最近错了什么题。',
      tools: composed.tools,
    ).toList();

    final calls = events.whereType<AgentToolCall>().map((t) => t.name).toList();
    final done = events.whereType<AgentDone>();
    // ignore: avoid_print
    print('工具调用: $calls');
    // ignore: avoid_print
    print('回答: ${done.isNotEmpty ? done.last.answer : '(无)'}');
    // 元数据问题应走 list_kb_docs，错题走 query_wrong_questions
    expect(calls, contains('list_kb_docs'));
    expect(calls, contains('query_wrong_questions'));
    expect(done, isNotEmpty);
    expect(done.last.answer, anyOf(contains('中国画论'), contains('词书')));
    expect(done.last.answer, contains('实践')); // 错题引用真实数据
    expect(events.whereType<AgentError>(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
