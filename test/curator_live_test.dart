// 策展器真模型实测（ZHIPU_KEY env）
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/llm_client.dart';
import 'package:three_cats_desk/features/agent/memory_curator.dart';

void main() {
  test('live 策展：真模型抽取对冲画像+三态掌握度', () async {
    final key = Platform.environment['ZHIPU_KEY'] ?? '';
    if (key.isEmpty) {
      // ignore: avoid_print
      print('跳过：未设置 ZHIPU_KEY');
      return;
    }
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    // 行为数据：政治 10 题 3 错、英语 5 题全对
    await db.insertQuestions([
      for (var i = 0; i < 10; i++)
        QuestionsCompanion.insert(
            id: 'p$i', stem: '政治题$i', optionsJson: '["a","b"]', answerIndex: 0,
            subject: const Value('政治')),
      for (var i = 0; i < 5; i++)
        QuestionsCompanion.insert(
            id: 'e$i', stem: '英语题$i', optionsJson: '["a","b"]', answerIndex: 0,
            subject: const Value('英语')),
    ]);
    var n = 0;
    for (var i = 0; i < 10; i++) {
      await db.insertAttempt(AttemptsCompanion.insert(
          id: 'a${n++}', questionId: 'p$i', selectedIndex: i < 3 ? 1 : 0, isCorrect: i >= 3));
    }
    for (var i = 0; i < 5; i++) {
      await db.insertAttempt(AttemptsCompanion.insert(
          id: 'a${n++}', questionId: 'e$i', selectedIndex: 0, isCorrect: true));
    }

    final r = await MemoryCurator(db, LlmClient()).curate(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4', model: 'glm-4.7', apiKey: key);
    // ignore: avoid_print
    print('RESULT: ${r.summary}');
    final scope = await db.getMemories('scope');
    for (final m in scope) {
      // ignore: avoid_print
      print('  - ${m.body}');
    }
    expect(r.dropped, 0, reason: '真模型不应触发禁词（触发了也正常拦截，但提示词已列明）');
    expect(scope, isNotEmpty);
    // 掌握度三态在（政治 practicing + 英语 mastered）
    expect(scope.any((m) => m.body.contains('政治')), isTrue);
    expect(scope.any((m) => m.body.contains('英语')), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
