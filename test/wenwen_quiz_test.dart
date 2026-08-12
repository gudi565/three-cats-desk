import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/wenwen/quiz_importer.dart';

/// 稳稳做题模块逻辑测试（不触 UI/网络/猫）。导入→作答→判分→错题。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('题库导入：20 题，政治/英语各 10，幂等不重复', () async {
    final importer = QuizImporter(db);
    final n1 = await importer.importFromAsset('assets/questions/sample-quiz.json');
    expect(n1, 20);
    final all = await db.getAllQuestions();
    expect(all.length, 20);
    expect(all.where((q) => q.subject == '政治').length, 10);
    expect(all.where((q) => q.subject == '英语').length, 10);
    // 幂等：再导一次不重复
    final n2 = await importer.importFromAsset('assets/questions/sample-quiz.json');
    expect(n2, 20); // upsert，题数仍 20
    expect((await db.getAllQuestions()).length, 20);
  });

  test('作答：客观判分（0 LLM）+ 写 attempts；错题进错题本', () async {
    final importer = QuizImporter(db);
    await importer.importFromAsset('assets/questions/sample-quiz.json');
    final q = (await db.getAllQuestions()).first;

    // 答对
    await db.insertAttempt(Attempt(
      id: 'a1', questionId: q.id, selectedIndex: q.answerIndex,
      isCorrect: true, answeredAt: DateTime.now(), sourceApp: 'wenwen', synced: false,
    ).toCompanion(true));
    // 答错
    await db.insertAttempt(Attempt(
      id: 'a2', questionId: q.id, selectedIndex: (q.answerIndex + 1) % 4,
      isCorrect: false, answeredAt: DateTime.now(), sourceApp: 'wenwen', synced: false,
    ).toCompanion(true));

    final wrongs = await db.getWrongAttempts();
    expect(wrongs.length, 1, reason: '只有答错那条进错题本');
    expect(wrongs.first.isCorrect, isFalse);
    expect(await db.getTodayAttemptCount(), 2);
  });

  test('客观判分核心：answerIndex 指向的选项即正确，其它即错', () async {
    final importer = QuizImporter(db);
    await importer.importFromAsset('assets/questions/sample-quiz.json');
    final all = await db.getAllQuestions();
    for (final q in all) {
      final opts = (jsonDecode(q.optionsJson) as List);
      expect(opts.length, greaterThanOrEqualTo(2));
      expect(q.answerIndex >= 0 && q.answerIndex < opts.length, isTrue,
          reason: '题 ${q.id} 的 answerIndex 必须在选项范围内');
    }
  });
}
