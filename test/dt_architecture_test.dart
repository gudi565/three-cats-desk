import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/prompts_zh.dart';
import 'package:three_cats_desk/features/agent/tool_composition.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';

/// DT2/DT3/DT4 落地验证：分块 system + 条件挂载 + KB 清单工具。
void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // 有错题 + 有笔记（挂载条件全真）
    await db.insertQuestions([
      QuestionsCompanion.insert(
          id: 'q1', stem: 's', optionsJson: '["a","b"]', answerIndex: 0),
    ]);
    await db.insertAttempt(AttemptsCompanion.insert(
        id: 'a1', questionId: 'q1', selectedIndex: 1, isCorrect: false));
    await db.upsertNote(NotesCompanion.insert(
        id: 'n1', title: const Value('考纲'), content: const Value('内容')));
  });
  tearDown(() async => db.close());

  test('DT3 条件挂载：全真 → 5 工具全挂；全假 → 只挂恒挂 2 个', () async {
    final all = composeTools(db,
        flags: const ToolMountFlags(
            hasWrongQuestions: true, hasKb: true, hasNotes: true),
        intimacyOf: () => 1,
        rag: null);
    expect(all.tools.keys, containsAll([
      'query_wrong_questions', 'query_today_progress',
      'query_syllabus_notes', 'list_kb_docs',
      'read_memory', 'write_preference', // M2 恒挂
    ]));

    final none = composeTools(db,
        flags: const ToolMountFlags(
            hasWrongQuestions: false, hasKb: false, hasNotes: false),
        intimacyOf: () => 1);
    // 空数据：错题/笔记/检索不挂，恒挂=进度+清单+read/write_memory
    expect(none.tools.keys, everyElement(isIn([
      'query_today_progress', 'list_kb_docs', 'read_memory', 'write_preference',
    ])));
    expect(none.tools.containsKey('query_wrong_questions'), isFalse);
    // 工具清单块同步收敛（空数据时模型看不到无意义工具）
    expect(none.toolsBlock, isNot(contains('query_wrong_questions')));
    expect(all.toolsBlock, contains('query_wrong_questions'));
  });

  test('DT2 buildSystem：分块顺序 + 语言指令在末尾 + 分隔线', () {
    final s = PromptsZh.buildSystem(
      extraBlocks: [(name: '用户档案', content: '目标：国美')],
      toolsBlock: '- `x` — 工具',
      kbManifest: '清单',
    );
    // 块序：身份 < 用户档案 < 循环 < 资料清单 < 工具 < 语言（末尾铁律）
    expect(s.indexOf('## 身份'), lessThan(s.indexOf('## 用户档案')));
    expect(s.indexOf('## 用户档案'), lessThan(s.indexOf('## 循环')));
    expect(s.indexOf('## 循环'), lessThan(s.indexOf('## 资料清单')));
    expect(s.indexOf('## 工具'), lessThan(s.indexOf('## 语言')));
    expect(s.endsWith(PromptsZh.language), isTrue); // 语言指令必须在最后
    expect(s, contains('---'));
  });

  test('DT4 list_kb_docs：清单统计 + pattern 过滤 + omitted', () async {
    final tool = ListKbDocsTool(db);
    final data = jsonDecode(await tool.execute({})) as Map<String, dynamic>;
    expect(data['total'], 2); // 题库1(政治)+笔记1（本测试没造词书）
    final docs = (data['docs'] as List).cast<Map<String, dynamic>>();
    expect(docs.any((d) => d['source'] == '题库(稳稳)'), isTrue);
    expect(docs.any((d) => d['source'] == '笔记(知知)'), isTrue);

    // pattern 过滤
    final filtered =
        jsonDecode(await tool.execute({'pattern': '考纲'})) as Map<String, dynamic>;
    final fdocs = (filtered['docs'] as List).cast<Map<String, dynamic>>();
    expect(fdocs, isNotEmpty);
    expect(fdocs.every((d) => d['name'].contains('考纲')), isTrue);

    // limit=1 → omitted 提示
    final limited =
        jsonDecode(await tool.execute({'limit': 1})) as Map<String, dynamic>;
    expect(limited['shown'], 1);
    expect(limited['omitted'], greaterThan(0));
  });
}
