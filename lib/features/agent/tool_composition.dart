import 'dart:convert';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';

/// 工具条件挂载 + 中文 hints（DT3/DT4，DeepTutor tool_composition 同款思想）。
///
/// 核心动机（DeepTutor 注释明言）：**工具面小 = 本地弱模型选择准**。
/// 空数据不挂对应工具——模型看不到无意义工具，就不会调了得到空结果再困惑。
///
/// hints 五字段（whenToUse/inputFormat 渲染进 system 的工具清单）：
/// 教模型"要不要调"，与 schema 的"怎么调"互补。

/// 条件探测：查数据源是否非空（composeTools 用）。
class ToolMountFlags {
  final bool hasWrongQuestions;
  final bool hasKb; // BM25 索引就绪且有内容
  final bool hasNotes;
  const ToolMountFlags({
    required this.hasWrongQuestions,
    required this.hasKb,
    required this.hasNotes,
  });

  static Future<ToolMountFlags> detect(AppDatabase db, {required bool ragReady}) async {
    final wrong = await db.getWrongAttempts();
    final notes = await db.getNotes();
    return ToolMountFlags(
      hasWrongQuestions: wrong.isNotEmpty,
      hasKb: ragReady,
      hasNotes: notes.isNotEmpty,
    );
  }
}

/// 挂载条件的工具包装。
class _MountedTool {
  final AgentTool tool;
  final bool Function(ToolMountFlags) mountWhen;
  final String whenToUse; // 中文 hints：何时调
  const _MountedTool(this.tool, this.mountWhen, this.whenToUse);
}

/// KB 清单元数据工具（DT4）：答"库里有什么"这类元问题——检索答不了。
class ListKbDocsTool extends AgentTool {
  final AppDatabase db;
  ListKbDocsTool(this.db)
      : super(
          'list_kb_docs',
          '列出用户知识库的文档清单与数量（词书、题库、笔记、文献分组统计）。'
              '当问题问的是知识库本身而非其内容时使用——有多少本词书、都叫什么、'
              '某科有多少题。检索片段绝不能回答这类问题。',
          {
            'type': 'object',
            'properties': {
              'pattern': {
                'type': 'string',
                'description': '可选，按名称子串过滤（如"美术"）',
              },
              'limit': {
                'type': 'integer',
                'description': '最多列出条数，默认 50，最大 200',
              },
            },
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final pattern = args['pattern']?.toString() ?? '';
    var limit = (args['limit'] as num?)?.toInt() ?? 50;
    if (limit < 1) limit = 1;
    if (limit > 200) limit = 200;

    final items = <Map<String, dynamic>>[];
    // 念念词书
    final decks = await db.getAllDecks();
    for (final d in decks) {
      if (pattern.isNotEmpty && !d.name.contains(pattern)) continue;
      items.add({'source': '词书(念念)', 'name': d.name, 'count': d.cardCount});
    }
    // 稳稳题库按科目
    final questions = await db.getAllQuestions();
    final bySubject = <String, int>{};
    for (final q in questions) {
      bySubject[q.subject] = (bySubject[q.subject] ?? 0) + 1;
    }
    for (final e in bySubject.entries) {
      if (pattern.isNotEmpty && !e.key.contains(pattern)) continue;
      items.add({'source': '题库(稳稳)', 'name': e.key, 'count': e.value});
    }
    // 知知笔记/考纲
    final notes = await db.getNotes();
    for (final n in notes) {
      if (pattern.isNotEmpty && !n.title.contains(pattern)) continue;
      items.add({'source': '笔记(知知)', 'name': n.title, 'count': null});
    }
    // 渊渊文献
    final lit = await db.getLiteratureList();
    if (lit.isNotEmpty && (pattern.isEmpty || '文献'.contains(pattern))) {
      items.add({'source': '文献(渊渊)', 'name': '文献库', 'count': lit.length});
    }

    final shown = items.take(limit).toList();
    return jsonEncode({
      'total': items.length,
      'shown': shown.length,
      if (items.length > shown.length) 'omitted': items.length - shown.length,
      'docs': shown,
      'note': '数量来自本地数据库的真实存放。另有遗漏可用 pattern 缩小范围。',
    });
  }
}

/// 组合工具集（条件挂载）+ 生成中文工具清单块（进 system）。
/// 返回 (tools, toolsBlock)。
({Map<String, AgentTool> tools, String toolsBlock}) composeTools(
  AppDatabase db, {
  required ToolMountFlags flags,
  required int Function() intimacyOf,
  dynamic rag, // RagIndexer（避免 core→features 反向依赖，用动态类型）
  bool Function(String)? searchFn, // rag.search 代理
}) {
  final wrong = QueryWrongQuestionsTool(db);
  final progress = QueryTodayProgressTool(db, intimacyOf: intimacyOf);
  final notes = QuerySyllabusNotesTool(db);
  final listKb = ListKbDocsTool(db);

  final mounted = <_MountedTool>[
    _MountedTool(
      wrong,
      (f) => f.hasWrongQuestions,
      '用户问"我错了什么题/哪里薄弱/讲讲错题/最近做题情况"时调用。',
    ),
    _MountedTool(
      progress,
      (_) => true, // 恒挂：进度总有意义
      '用户问"我今天学得怎么样/进度如何/复习了多少"时调用。',
    ),
    _MountedTool(
      notes,
      (f) => f.hasNotes,
      '检索用户的考纲与笔记（知知模块），答疑引用他自己的资料时使用。',
    ),
    _MountedTool(
      listKb,
      (_) => true, // 恒挂：元数据问题总有意义
      '问题问的是知识库本身（多少词书/叫什么名/某科几道题）时调用——检索答不了元问题。',
    ),
    if (rag != null && searchFn != null)
      _MountedTool(
        _RagSearchTool(rag, searchFn),
        (f) => f.hasKb,
        '在全知识库做相关性检索（词书卡片+笔记+考纲全文）。答疑、讲解、'
        '引用"他自己的资料"时优先用这个（比 query_syllabus_notes 覆盖广、排序好）。',
      ),
  ];

  final tools = <String, AgentTool>{};
  final lines = <String>[];
  for (final m in mounted) {
    if (!m.mountWhen(flags)) continue;
    tools[m.tool.name] = m.tool;
    lines.add('- `${m.tool.name}` — ${m.tool.description.split('。').first}。\n'
        '  适用场景: ${m.whenToUse}');
  }
  return (tools: tools, toolsBlock: lines.join('\n'));
}

/// search_knowledge 工具（rag 注入版，避免类型依赖）。
class _RagSearchTool extends AgentTool {
  final dynamic rag;
  final bool Function(String) _search;
  _RagSearchTool(this.rag, this._search)
      : super(
          'search_knowledge',
          '在用户的知识库里全文检索（他的词书卡片、笔记、考纲）。答疑、讲解、'
              '引用"他自己的资料"时优先用这个。',
          {
            'type': 'object',
            'properties': {
              'query': {
                'type': 'string',
                'description': '检索词（自然词组即可，如"谢赫六法"、"矛盾的特殊性"）',
              },
            },
            'required': ['query'],
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final query = args['query']?.toString() ?? '';
    if (query.isEmpty) return jsonEncode({'error': 'query 必填'});
    try {
      final hits = rag.search(query, topK: 8) as List<(String, double)>;
      return jsonEncode({
        'query': query,
        'hits': [
          for (final (title, score) in hits)
            {'title': title, 'score': score.toStringAsFixed(2)}
        ],
      });
    } catch (e) {
      return jsonEncode({'error': '检索失败: $e'});
    }
  }
}
