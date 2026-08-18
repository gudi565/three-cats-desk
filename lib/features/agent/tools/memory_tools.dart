import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';

/// 画像读写工具（M2，2026-08-16）。
///
/// read_memory（DeepTutor 同名工具同款契约）：无参返回四槽拼接——
/// 智能体据此调整"怎么讲、举什么例、问什么"。
/// write_preference：仅 preferences 槽；用户显式偏好；幂等（判重命中返回已存）。

class ReadMemoryTool extends AgentTool {
  final AppDatabase db;
  ReadMemoryTool(this.db)
      : super(
          'read_memory',
          '读取该用户的持久化画像：近期活动、学习风格、知识点掌握度、显式偏好。'
              '当回答的语气、深度、举例或讲解详略可以针对该用户调整时调用。'
              '纯事实类问题不用调。每个 turn 最多调一次。',
          {'type': 'object', 'properties': {}},
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final slots = {
      'recent': '近期活动',
      'profile': '学习风格',
      'scope': '知识点掌握度',
      'preferences': '显式偏好',
    };
    final out = <String, dynamic>{};
    for (final e in slots.entries) {
      final items = await db.getMemories(e.key);
      out[e.value] = [for (final m in items) m.body];
    }
    final hasAny = out.values.any((v) => (v as List).isNotEmpty);
    if (!hasAny) {
      return jsonEncode({'note': '还没有画像。按通用方式回答。'});
    }
    return jsonEncode(out);
  }
}

class WritePreferenceTool extends AgentTool {
  final AppDatabase db;
  WritePreferenceTool(this.db)
      : super(
          'write_preference',
          '记住用户显式表达的偏好（如"我喜欢简短讲解""别用英文术语"）。'
              '只记他明确说出的偏好，不要推断。尽量用他的原话，≤240 字。',
          {
            'type': 'object',
            'properties': {
              'text': {
                'type': 'string',
                'description': '偏好内容（用户原话优先，≤240 字）',
              },
            },
            'required': ['text'],
          },
        );

  static const _uuid = Uuid();

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final text = args['text']?.toString().trim() ?? '';
    if (text.isEmpty) return jsonEncode({'error': 'text 必填'});
    if (text.length > 240) {
      return jsonEncode({'error': '超过 240 字，请精简（保留核心偏好）'});
    }
    // 幂等：同义判重（空白归一 casefold）
    final dup = await db.findDuplicatePreference(text);
    if (dup != null) {
      return jsonEncode({'status': 'already_saved', 'id': dup.id});
    }
    final id = 'm_${_uuid.v4()}';
    await db.insertMemory(MemoryEntriesCompanion.insert(
        id: id, slot: 'preferences', body: text, refs: const Value('chat:agent')));
    return jsonEncode({'status': 'saved', 'id': id});
  }
}
