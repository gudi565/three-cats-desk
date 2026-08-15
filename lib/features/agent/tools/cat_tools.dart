import 'dart:convert';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/rag/rag_indexer.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';

/// 五猫工具集 v1（P1-2，2026-08-15）——智能体读得懂数据的第一步。
///
/// 三个只读工具（不写：先验证"引用你的数据回答"价值，再开写入工具）：
///   1. query_wrong_questions 稳稳错题（讲解/诊断薄弱点的数据源）
///   2. query_today_progress 今日进度（复习/专注/猫——规划与鼓励的数据源）
///   3. query_syllabus_notes 考纲+笔记检索（答疑引用他自己的资料）
///
/// 工具定义=给模型看的 prompt（深研结论：与系统提示词同级打磨）——
/// description 写清"什么时候该用"，参数 schema 写清含义。

/// 稳稳：查错题（默认最近 10 条，可按科目过滤）。
class QueryWrongQuestionsTool extends AgentTool {
  final AppDatabase db;
  QueryWrongQuestionsTool(this.db)
      : super(
          'query_wrong_questions',
          '查询用户做错的题（稳稳做题模块的错题记录）。当用户问"我错了什么题/哪里薄弱/'
              '给我讲讲错题/最近做题情况"时使用。返回题目、用户所选答案与正确答案。',
          {
            'type': 'object',
            'properties': {
              'subject': {
                'type': 'string',
                'description': '按科目过滤，如"政治"、"英语"；不传=全部科目',
              },
              'limit': {
                'type': 'integer',
                'description': '返回条数上限，默认 10，最大 30',
              },
            },
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final all = await db.getWrongAttempts();
    final subject = args['subject']?.toString();
    var limit = (args['limit'] as num?)?.toInt() ?? 10;
    if (limit < 1) limit = 1;
    if (limit > 30) limit = 30;

    // 关联题目内容（attempts 只有 id/所选）
    final questions = await db.getAllQuestions();
    final qById = {for (final q in questions) q.id: q};

    final rows = <Map<String, dynamic>>[];
    for (final a in all) {
      if (rows.length >= limit) break;
      final q = qById[a.questionId];
      if (q == null) continue;
      if (subject != null && subject.isNotEmpty && !q.subject.contains(subject)) {
        continue;
      }
      final opts = (jsonDecode(q.optionsJson) as List).cast<String>();
      rows.add({
        'question_id': q.id,
        'subject': q.subject,
        'stem': q.stem,
        'options': opts,
        'user_answer': a.selectedIndex >= 0 && a.selectedIndex < opts.length
            ? opts[a.selectedIndex]
            : '(未作答)',
        'correct_answer':
            q.answerIndex >= 0 && q.answerIndex < opts.length ? opts[q.answerIndex] : '',
        'explanation': q.explanation ?? '',
        'wrong_at': a.answeredAt.toIso8601String(),
      });
    }
    return jsonEncode({
      'total_wrong': all.length,
      'returned': rows.length,
      'wrong_questions': rows,
    });
  }
}

/// 今日进度：复习张数 + 专注分钟 + 猫亲密度 + 活跃天数。
class QueryTodayProgressTool extends AgentTool {
  final AppDatabase db;
  final int Function() intimacyOf; // 猫亲密度（catProvider 在 UI 层，注入读取函数）
  QueryTodayProgressTool(this.db, {required this.intimacyOf})
      : super(
          'query_today_progress',
          '查询用户今天的学习进度：复习了多少张卡、专注了多少分钟、猫亲密度、累计活跃天数。'
              '当用户问"我今天学得怎么样/进度如何/陪我聊聊复习计划"时使用。',
          {'type': 'object', 'properties': {}},
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final focus = await db.getTodayFocusSessions();
    final focusMinutes = focus.fold<int>(0, (s, f) => s + f.actualSeconds) ~/ 60;
    final attempts = await db.getTodayAttemptCount();
    final activity = await db.getRecentActivity(1);
    final activeDays = await db.countActiveDays();
    return jsonEncode({
      'today': {
        'reviewed_cards': activity.isNotEmpty ? activity.first.reviewed : 0,
        'focus_minutes': focusMinutes,
        'focus_sessions': focus.where((f) => f.completed).length,
        'quiz_attempts': attempts,
      },
      'total': {
        'active_days': activeDays,
        'cat_intimacy': intimacyOf(),
      },
    });
  }
}

/// 知知：考纲/笔记检索（关键词包含匹配——P2-2 BM25 上线前的朴素版）。
class QuerySyllabusNotesTool extends AgentTool {
  final AppDatabase db;
  QuerySyllabusNotesTool(this.db)
      : super(
          'query_syllabus_notes',
          '检索用户的考纲与笔记内容（知知模块）。当答疑需要引用"他自己的资料"时使用——'
              '比如问考纲里的知识点、某个概念在他笔记里的表述。返回匹配的笔记片段。',
          {
            'type': 'object',
            'properties': {
              'keyword': {
                'type': 'string',
                'description': '检索关键词（如"谢赫六法"、"矛盾"）',
              },
            },
            'required': ['keyword'],
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final keyword = args['keyword']?.toString() ?? '';
    if (keyword.isEmpty) return jsonEncode({'error': 'keyword 必填'});
    final notes = await db.getNotes();
    final hits = <Map<String, dynamic>>[];
    for (final n in notes) {
      // 标题或正文包含关键词 → 命中，摘取关键词所在段落
      if (n.title.contains(keyword) || n.content.contains(keyword)) {
        final para = _paragraphAround(n.content, keyword);
        hits.add({'note_id': n.id, 'title': n.title, 'snippet': para});
      }
      if (hits.length >= 5) break;
    }
    return jsonEncode({'keyword': keyword, 'hits': hits});
  }

  /// 关键词所在段落（前后各扩一段，给模型足够上下文）。
  String _paragraphAround(String content, String keyword) {
    final paras = content.split('\n');
    for (var i = 0; i < paras.length; i++) {
      if (paras[i].contains(keyword)) {
        final from = i > 0 ? i - 1 : 0;
        final to = (i + 2 < paras.length) ? i + 2 : paras.length;
        return paras.sublist(from, to).join('\n');
      }
    }
    return content.substring(0, content.length.clamp(0, 300));
  }
}

/// 知识库 BM25 检索（P2-2）：智能体引用"他自己的资料"的主通道。
/// 覆盖念念全部卡片 + 知知笔记/考纲；中文 bigram 分词写读同源。
class SearchKnowledgeTool extends AgentTool {
  final RagIndexer rag;
  SearchKnowledgeTool(this.rag)
      : super(
          'search_knowledge',
          '在用户的知识库里全文检索（他的词书卡片、笔记、考纲）。答疑、讲解、'
              '引用"他自己的资料"时先用这个；query_syllabus_notes 只查笔记且是包含匹配，'
              '这个是全库相关性排序，优先用它。',
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
    if (!rag.isReady) {
      return jsonEncode({'error': '知识库尚未就绪（请先导入资源包）'});
    }
    final hits = rag.search(query, topK: 8);
    return jsonEncode({
      'query': query,
      'hits': [
        for (final (title, score) in hits) {'title': title, 'score': score.toStringAsFixed(2)}
      ],
    });
  }
}

/// 组装默认工具集（provider 层用）。
Map<String, AgentTool> buildCatTools(AppDatabase db,
        {required int Function() intimacyOf, RagIndexer? rag}) =>
    {
      'query_wrong_questions': QueryWrongQuestionsTool(db),
      'query_today_progress': QueryTodayProgressTool(db, intimacyOf: intimacyOf),
      'query_syllabus_notes': QuerySyllabusNotesTool(db),
      if (rag != null) 'search_knowledge': SearchKnowledgeTool(rag),
    };
