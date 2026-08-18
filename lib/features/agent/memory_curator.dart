import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/llm_client.dart';

/// 画像策展器（M3，2026-08-16）。
///
/// 数据源=五猫行为事件（做题/复习/专注）→ LLM 抽取带对冲的画像条目 +
/// 掌握度三态。依据（学习科学深研 v2 已验证）：
///   - Bokosmaty 门控规则：掌握度基于**行为事件**而非年级代理
///   - DeepTutor update_l3 禁词闸：防绝对化（"完全掌握/总是/从不"）
///   - 对冲措辞："在 N 次做题中，X" 而非 "他 X"
///
/// 触发：设置页"整理记忆"手动按钮（本地无 cron，手动最稳）。

class MemoryCurator {
  final AppDatabase db;
  final LlmClient llm;
  MemoryCurator(this.db, this.llm);

  static const _uuid = Uuid();

  /// 禁词闸（DeepTutor 禁词清单中文版）：命中即丢弃该条目。
  static const bannedWords = [
    '深刻', '彻底', '完美掌握', '完全理解', '完全掌握', '专家',
    '热爱', '总是', '从不', '永远', '必定', '无疑',
    'deeply', 'truly', 'mastered', 'expert', 'passionate', 'always', 'never',
  ];

  /// 整理一次画像。返回 {written, dropped, scopeCount} 摘要。
  Future<CuratorResult> curate({
    required String baseUrl,
    required String model,
    required String apiKey,
  }) async {
    // 1. 收集行为证据
    final attempts = await db.select(db.attempts).get();
    final questions = await db.getAllQuestions();
    final qById = {for (final q in questions) q.id: q};
    final activity = await db.getRecentActivity(14);

    if (attempts.isEmpty) {
      return CuratorResult(written: 0, dropped: 0, scope: 0, note: '还没有做题记录，无从整理');
    }

    // 2. 按科目聚合行为统计（确定性代码，非 LLM——数字不撒谎）
    final bySubject = <String, SubjectStat>{};
    for (final a in attempts) {
      final q = qById[a.questionId];
      if (q == null) continue;
      final s = bySubject.putIfAbsent(q.subject, () => SubjectStat());
      s.total++;
      if (!a.isCorrect) s.wrong++;
    }
    final evidence = {
      'attempts_total': attempts.length,
      'by_subject': {
        for (final e in bySubject.entries)
          e.key: {'total': e.value.total, 'wrong': e.value.wrong},
      },
      'active_days_14d': activity.length,
    };

    // 3. LLM 抽取（带禁词+对冲指令）
    final resp = await llm.chat(
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey,
      messages: [
        {
          'role': 'system',
          'content': '你是学习画像策展器。基于做题行为统计，输出关于这位考研生的画像条目。\n'
              '输出恰好一个 JSON 对象：\n'
              '{"facts": [{"text": "<≤240字，对冲措辞>", "slot": "scope|profile|recent"}], '
              '"mastery": [{"topic": "<科目或知识点>", "state": "novice|practicing|mastered"}]}\n\n'
              '硬性规则：\n'
              '- text 必须对冲：形如「在 N 次做题中，X 科错 M 次」或「近 14 天活跃 K 天」，'
              '禁止绝对化判断。\n'
              '- 禁止这些词：${bannedWords.join('、')}。命中即弃。\n'
              '- mastery.state 判定（基于行为）：novice=错多于对或刚接触；'
              'practicing=有对有错；mastered=连续对且 ≥5 次。\n'
              '- 只用给定的统计数字，不要编造数字。\n'
              '- facts ≤3 条，mastery 每科 ≤1 条。',
        },
        {'role': 'user', 'content': jsonEncode(evidence)},
      ],
    );

    // 4. 解析 + 禁词闸 + 写库
    var written = 0, dropped = 0, scopeCount = 0;
    final Map<String, dynamic> parsed;
    try {
      final raw = resp.content;
      final jsonStart = raw.indexOf('{');
      final jsonEnd = raw.lastIndexOf('}');
      parsed = jsonDecode(raw.substring(jsonStart, jsonEnd + 1)) as Map<String, dynamic>;
    } catch (_) {
      return CuratorResult(written: 0, dropped: 0, scope: 0, note: '策展输出解析失败（重试即可）');
    }

    // 重建 scope 槽（幂等：先清后写）
    await db.clearSlot('scope');
    for (final f in (parsed['facts'] as List? ?? [])) {
      final m = f as Map<String, dynamic>;
      final text = (m['text'] ?? '').toString();
      final slot = (m['slot'] ?? 'scope').toString();
      if (text.isEmpty || text.length > 240) continue;
      if (_hitsBanned(text)) {
        dropped++;
        continue;
      }
      await db.insertMemory(MemoryEntriesCompanion.insert(
          id: 'm_${_uuid.v4()}',
          slot: slot == 'profile' || slot == 'recent' ? slot : 'scope',
          body: text,
          refs: const Value('curator:attempts')));
      written++;
      if (slot == 'scope') scopeCount++;
    }
    // 掌握度三态写 scope 槽（讲解门控读这里）
    for (final mm in (parsed['mastery'] as List? ?? [])) {
      final m = mm as Map<String, dynamic>;
      final topic = (m['topic'] ?? '').toString();
      final state = (m['state'] ?? '').toString();
      if (topic.isEmpty || !['novice', 'practicing', 'mastered'].contains(state)) {
        continue;
      }
      await db.insertMemory(MemoryEntriesCompanion.insert(
          id: 'm_${_uuid.v4()}',
          slot: 'scope',
          body: '$topic：${stateLabel(state)}',
          refs: const Value('curator:mastery')));
      scopeCount++;
    }

    return CuratorResult(written: written, dropped: dropped, scope: scopeCount);
  }

  static String stateLabel(String s) => switch (s) {
        'novice' => '未掌握',
        'practicing' => '练习中',
        'mastered' => '已掌握',
        _ => s,
      };

  static bool _hitsBanned(String text) =>
      bannedWords.any(text.contains);
}

class SubjectStat {
  int total = 0;
  int wrong = 0;
}

class CuratorResult {
  final int written;
  final int dropped;
  final int scope;
  final String note;
  CuratorResult({
    required this.written,
    required this.dropped,
    required this.scope,
    this.note = '',
  });

  String get summary => note.isNotEmpty
      ? note
      : '画像已更新：写入 $written 条（掌握度 $scope 条），禁词拦截 $dropped 条';
}
