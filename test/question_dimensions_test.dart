import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/importers/quiz_importer.dart';

/// C3 真题维度验证：year/questionType/knowledgeTags 三列 + 导入兼容 + 薄弱点聚合。
void main() {
  late AppDatabase db;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async => db.close());

  test('新字段导入（带年份/题型/标签）+ 旧格式兼容（无字段回落默认）', () async {
    final importer = QuizImporter(db);
    final json = jsonEncode([
      {
        'id': 'q1', 'stem': '实践是检验真理的唯一标准', 'options': ['因为直接现实性', '因为社会性'],
        'answerIndex': 0, 'subject': '政治', 'year': 2024, 'questionType': '单选',
        'knowledgeTags': ['马原-认识论', '真理检验']
      },
      {
        'id': 'q2', 'stem': '旧格式题（无新字段）', 'options': ['a', 'b'], 'answerIndex': 0
      },
    ]);
    final n = await importer.importFromBytes(utf8.encode(json));
    expect(n, 2);
    final qs = await db.getAllQuestions();
    final q1 = qs.firstWhere((q) => q.id == 'q1');
    expect(q1.year, 2024);
    expect(q1.questionType, '单选');
    expect(jsonDecode(q1.knowledgeTags), ['马原-认识论', '真理检验']);
    final q2 = qs.firstWhere((q) => q.id == 'q2');
    expect(q2.year, isNull); // 旧格式回落
    expect(q2.questionType, '单选');
    expect(q2.knowledgeTags, '[]');
  });

  test('薄弱点聚合：按 knowledgeTags 统计错题数（降序+未标记兜底）', () async {
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1', stem: 's1', optionsJson: '["a","b"]', answerIndex: 0,
          knowledgeTags: const Value('["马原-矛盾观"]')),
      QuestionsCompanion.insert(
          id: 'q2', stem: 's2', optionsJson: '["a","b"]', answerIndex: 0,
          knowledgeTags: const Value('["马原-矛盾观","马原-认识论"]')),
      QuestionsCompanion.insert(
          id: 'q3', stem: 's3', optionsJson: '["a","b"]', answerIndex: 0),
    ]);
    // q1 q2 错，q3 对
    await db.insertAttempt(AttemptsCompanion.insert(id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));
    await db.insertAttempt(AttemptsCompanion.insert(id: 'a2', questionId: 'q2', selectedIndex: 1, isCorrect: false));
    await db.insertAttempt(AttemptsCompanion.insert(id: 'a3', questionId: 'q3', selectedIndex: 0, isCorrect: true));

    final byTag = await db.getWrongByKnowledgeTag();
    expect(byTag['马原-矛盾观'], 2);
    expect(byTag['马原-认识论'], 1);
    expect(byTag.containsKey('未标记'), isFalse, reason: 'q3 没错不计');
    // 降序
    expect(byTag.keys.first, '马原-矛盾观');
  });

  test('全错但无标签 → 未标记兜底', () async {
    await db.insertQuestions([
      QuestionsCompanion.insert(id: 'q1', stem: 's', optionsJson: '["a","b"]', answerIndex: 0),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));
    final byTag = await db.getWrongByKnowledgeTag();
    expect(byTag['未标记'], 1);
  });
}
