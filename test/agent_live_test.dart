// 真模型智能体链路验证（本地手动跑，不进 CI）：ZHIPU_KEY env
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/agent_events.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 造一条真实错题（稳稳数据）
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1',
          stem: '实践是检验真理的唯一标准，因为',
          optionsJson: '["实践具有直接现实性","实践是社会活动","实践有能动性","实践形式多样"]',
          answerIndex: 0,
          explanation: Value('直接现实性是关键')),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));
  });
  tearDown(() async => db.close());

  test('live 真模型+真工具：问"我错了什么题"应调工具并引用数据', () async {
    final key = Platform.environment['ZHIPU_KEY'] ?? '';
    if (key.isEmpty) {
      // ignore: avoid_print
      print('跳过：未设置 ZHIPU_KEY');
      return;
    }
    final tools = buildCatTools(db, intimacyOf: () => 7);
    final loop = AgentLoop();
    final events = await loop
        .run(
          baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
          model: 'glm-4.7',
          apiKey: key,
          systemPrompt:
              '你是三猫书桌的考研陪伴智能体。你可以调用工具查看用户的真实数据，回答要基于工具结果，不要编造。',
          userMessage: '我最近错了哪些题？给我讲讲。',
          tools: tools,
        )
        .toList();

    final toolCalls = events.whereType<AgentToolCall>().toList();
    final done = events.whereType<AgentDone>().toList();
    // ignore: avoid_print
    print('工具调用: ${toolCalls.map((t) => t.name).toList()}');
    // ignore: avoid_print
    print('回答: ${done.isNotEmpty ? done.last.answer : "(无)"}');
    expect(toolCalls.map((t) => t.name), contains('query_wrong_questions'),
        reason: '模型应主动调错题工具');
    expect(done, isNotEmpty);
    // 回答应引用真实数据（题干关键词）
    expect(done.last.answer, anyOf(contains('实践'), contains('直接现实性')));
    expect(events.whereType<AgentError>(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
