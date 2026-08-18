import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/llm_client.dart';
import 'package:three_cats_desk/features/agent/memory_curator.dart';
import 'package:three_cats_desk/features/agent/tools/memory_tools.dart';

/// M2/M3 画像验证：读写工具 + 策展器（禁词闸/对冲/三态/幂等重建）。
void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 行为数据：政治 10 题 3 错、英语 5 题 0 错
    final qs = <QuestionsCompanion>[
      for (var i = 0; i < 10; i++)
        QuestionsCompanion.insert(
            id: 'p$i', stem: '政治题$i', optionsJson: '["a","b"]', answerIndex: 0,
            subject: const Value('政治')),
      for (var i = 0; i < 5; i++)
        QuestionsCompanion.insert(
            id: 'e$i', stem: '英语题$i', optionsJson: '["a","b"]', answerIndex: 0,
            subject: const Value('英语')),
    ];
    await db.insertQuestions(qs);
    var n = 0;
    for (var i = 0; i < 10; i++) {
      await db.insertAttempt(AttemptsCompanion.insert(
          id: 'a${n++}', questionId: 'p$i', selectedIndex: i < 3 ? 1 : 0, isCorrect: i >= 3));
    }
    for (var i = 0; i < 5; i++) {
      await db.insertAttempt(AttemptsCompanion.insert(
          id: 'a${n++}', questionId: 'e$i', selectedIndex: 0, isCorrect: true));
    }
  });
  tearDown(() async => db.close());

  test('M2 read_memory：空画像友好提示；写后四槽拼接', () async {
    final read = ReadMemoryTool(db);
    final empty = jsonDecode(await read.execute({})) as Map<String, dynamic>;
    expect(empty['note'], contains('还没有画像'));

    await db.insertMemory(MemoryEntriesCompanion.insert(
        id: 'm1', slot: 'scope', body: '政治：练习中'));
    final data = jsonDecode(await read.execute({})) as Map<String, dynamic>;
    expect((data['知识点掌握度'] as List), isNotEmpty);
    expect((data['显式偏好'] as List), isEmpty);
  });

  test('M2 write_preference：保存/幂等/超长拒绝', () async {
    final w = WritePreferenceTool(db);
    final r1 = jsonDecode(await w.execute({'text': '喜欢 简短  讲解'}));
    expect(r1['status'], 'saved');
    // 幂等
    final r2 = jsonDecode(await w.execute({'text': '喜欢 简短 讲解'}));
    expect(r2['status'], 'already_saved');
    // 超长
    final r3 = jsonDecode(await w.execute({'text': '长' * 300}));
    expect(r3['error'], contains('240'));
  });

  test('M3 策展器：LLM 抽取+禁词闸+三态写 scope+幂等重建', () async {
    final llm = CuratorLlm()
      ..response = const LlmResponse(
          content: '{"facts": [{"text": "在 15 次做题中，政治错 3 次、英语全对", "slot": "scope"},'
              '{"text": "他完全掌握了英语词汇", "slot": "scope"}], '
              '"mastery": [{"topic": "政治", "state": "practicing"}, {"topic": "英语", "state": "mastered"}, {"topic": "坏状态", "state": "unknown"}]}',
          toolCalls: []);
    final curator = MemoryCurator(db, llm);
    final r = await curator.curate(baseUrl: 'x', model: 'm', apiKey: 'k');

    // 禁词闸：'完全掌握' 那条被拦截
    expect(r.dropped, 1);
    // 对冲条目 + 两条合法 mastery 写入 scope
    final scope = await db.getMemories('scope');
    expect(scope.any((m) => m.body.contains('在 15 次做题中')), isTrue);
    expect(scope.any((m) => m.body.contains('政治：练习中')), isTrue);
    expect(scope.any((m) => m.body.contains('英语：已掌握')), isTrue);
    expect(scope.any((m) => m.body.contains('坏状态')), isFalse); // 非法 state 丢弃
    expect(r.scope, 3);

    // 幂等重建：再跑一次 scope 不翻倍（先清后写）
    final r2 = await curator.curate(baseUrl: 'x', model: 'm', apiKey: 'k');
    expect((await db.getMemories('scope')).length, 3);
    expect(r2.scope, 3);
  });

  test('M3 无做题记录 → 友好返回不调 LLM', () async {
    final empty = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => empty.close());
    final curator = MemoryCurator(empty, CuratorLlm()..called = false);
    final r = await curator.curate(baseUrl: 'x', model: 'm', apiKey: 'k');
    expect(r.note, contains('没有做题记录'));
  });
}

/// 策展用假 LLM。
class CuratorLlm extends LlmClient {
  LlmResponse response = const LlmResponse(content: '{}', toolCalls: []);
  bool called = true;
  @override
  Future<LlmResponse> chat({
    required String baseUrl,
    required String model,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    if (!called) throw StateError('不应调用 LLM');
    return response;
  }
}
