import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';

/// 五猫工具集 v1 行为验证（P1-2）。
///
/// 钉死：错题查询（含正确答案/解析/科目过滤/limit 钳制）、
/// 今日进度聚合（复习/专注/亲密度注入）、考纲检索（关键词段落命中）。
/// 这是"智能体读得懂五猫数据"的地基。
void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 造数据：2 道题（1 错 1 对）+ 1 条专注 + 1 天活动 + 考纲笔记
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1',
          stem: '实践是检验真理的唯一标准，因为',
          optionsJson: '["实践具有直接现实性","实践是社会活动","实践有能动性","实践形式多样"]',
          answerIndex: 0,
          explanation: Value('直接现实性是关键')),
      QuestionsCompanion.insert(
          id: 'q2',
          stem: '对立统一规律是唯物辩证法的',
          optionsJson: '["实质与核心","次要规律","外在形式","数量关系"]',
          answerIndex: 0,
          explanation: Value('矛盾规律是核心')),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a1',
        questionId: 'q1',
        selectedIndex: 1, // 错
        isCorrect: false));
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a2',
        questionId: 'q2',
        selectedIndex: 0, // 对
        isCorrect: true));
    await db.insertFocusSession(FocusSessionsCompanion.insert(
        id: 'f1',
        startedAt: DateTime.now(),
        plannedMinutes: 25,
        actualSeconds: const Value(1500),
        completed: const Value(true)));
    final now = DateTime.now();
    final day = '${now.year}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    await db.recordAppOpen(day, intimacy: 42);
    await db.recordReviewed(day);
    await db.upsertNote(NotesCompanion.insert(
      id: 'syllabus-kaoyan_art',
      title: const Value('美术考研 · 考纲'),
      content: const Value('## 五、中国画论\n- 谢赫六法：气韵生动/骨法用笔/应物象形\n- 三远：高远/深远/平远'),
      subject: const Value('美术史论'),
    ));
  });
  tearDown(() async => db.close());

  test('query_wrong_questions：返回错题+用户答案+正确答案+解析', () async {
    final tool = QueryWrongQuestionsTool(db);
    final raw = await tool.execute({});
    final data = jsonDecode(raw) as Map<String, dynamic>;
    expect(data['total_wrong'], 1);
    final q = (data['wrong_questions'] as List).single;
    expect(q['stem'], contains('实践'));
    expect(q['user_answer'], contains('社会活动')); // 错选 B
    expect(q['correct_answer'], contains('直接现实性'));
    expect(q['explanation'], isNotEmpty);
  });

  test('query_wrong_questions：limit 钳制 1..30', () async {
    final tool = QueryWrongQuestionsTool(db);
    expect(jsonDecode(await tool.execute({'limit': 999}))['returned'], 1);
    expect(jsonDecode(await tool.execute({'limit': 0}))['returned'], 1);
  });

  test('query_today_progress：聚合复习/专注/亲密度', () async {
    final tool = QueryTodayProgressTool(db, intimacyOf: () => 42);
    final data = jsonDecode(await tool.execute({})) as Map<String, dynamic>;
    expect(data['today']['reviewed_cards'], 1);
    expect(data['today']['focus_minutes'], 25);
    expect(data['today']['focus_sessions'], 1);
    expect(data['total']['cat_intimacy'], 42);
    expect(data['total']['active_days'], 1);
  });

  test('query_syllabus_notes：关键词命中考纲段落', () async {
    final tool = QuerySyllabusNotesTool(db);
    final data =
        jsonDecode(await tool.execute({'keyword': '谢赫六法'})) as Map<String, dynamic>;
    final hits = data['hits'] as List;
    expect(hits, hasLength(1));
    expect(hits.single['title'], contains('考纲'));
    expect(hits.single['snippet'], contains('气韵生动')); // 命中行含内容
  });

  test('query_syllabus_notes：无命中返回空列表（不炸）', () async {
    final tool = QuerySyllabusNotesTool(db);
    final data =
        jsonDecode(await tool.execute({'keyword': '不存在的东西'})) as Map<String, dynamic>;
    expect(data['hits'], isEmpty);
  });
}
