import 'dart:convert';

import 'package:three_cats_desk/features/agent/agent_loop.dart';

/// Solve 三件套：solve_plan / solve_finish_step / solve_replan（DT 深读落地，2026-08-16）。
///
/// DeepTutor solve 同款设计哲学：**模型负责解题智能，引擎持有确定性状态**
/// （计划 + 步骤完成标记 + 重规划预算）——"先提交计划、不许跳步、有界重规划"
/// 全部由引擎状态机保证，而非提示词自觉。
///
/// 用法（错题深度讲解模式）：给工具集注入这三件套 + 常规工具，系统提示用
/// PromptsZh.solveSystem（照抄 DeepTutor zh system.md 换三猫工具名）。
/// SolveSession 单轮内存态（同 DeepTutor：不持久化，计划随 tool 结果留在对话里）。

class SolveStep {
  final String id; // S1..Sn（引擎生成，不信模型）
  final String goal;
  bool done = false;
  String summary = '';
  SolveStep(this.id, this.goal);

  Map<String, dynamic> toMap() => {'id': id, 'goal': goal, 'done': done};
}

class SolveSession {
  final String sessionId;
  String analysis = '';
  List<SolveStep> steps = [];
  int replans = 0;
  final int maxReplans;

  static const maxSteps = 12;

  SolveSession(this.sessionId, {this.maxReplans = 2});

  /// 建计划（步骤 id 由引擎重编 S1..Sn——不信模型给的 id）。
  bool setPlan(String analysis, List<String> goals) {
    this.analysis = analysis;
    steps = [
      for (var i = 0; i < goals.length && i < maxSteps; i++)
        SolveStep('S${i + 1}', goals[i])
    ];
    return steps.isNotEmpty;
  }

  /// 重规划：预算尽返回 false 且不动原计划（引擎门）。
  bool replan(String newAnalysis, List<String> goals) {
    if (replans >= maxReplans) return false;
    replans++;
    return setPlan(newAnalysis, goals);
  }

  SolveStep? markDone(String stepId, String summary) {
    for (final s in steps) {
      if (s.id == stepId) {
        s.done = true;
        s.summary = summary.trim();
        return s;
      }
    }
    return null;
  }

  SolveStep? get nextStep {
    for (final s in steps) {
      if (!s.done) return s;
    }
    return null;
  }

  bool get allDone => steps.isNotEmpty && steps.every((s) => s.done);

  List<Map<String, dynamic>> map() => [for (final s in steps) s.toMap()];
}

/// solve_plan：先提交计划再动手（第一件事铁律）。
class SolvePlanTool extends AgentTool {
  final SolveSession session;
  SolvePlanTool(this.session)
      : super(
          'solve_plan',
          '为讲解/解题先提交计划：一段简短分析 + 有序步骤列表。'
              '在做任何事之前先调用这个——调用之前绝不开始求解。'
              '多数题目 2-6 步；很简单的题一步也行。',
          {
            'type': 'object',
            'properties': {
              'analysis': {
                'type': 'string',
                'description': '一两句话：题目在问什么、你的思路',
              },
              'steps': {
                'type': 'array',
                'description': '有序步骤，每项 {"goal": "短祈使句目标"}',
                'items': {
                  'type': 'object',
                  'properties': {'goal': {'type': 'string'}},
                  'required': ['goal'],
                },
              },
            },
            'required': ['analysis', 'steps'],
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final analysis = args['analysis']?.toString() ?? '';
    final goals = [
      for (final s in (args['steps'] as List? ?? const []))
        (((s as Map)['goal'] ?? '') as String).trim(),
    ].where((g) => g.isNotEmpty).toList();
    if (goals.isEmpty) {
      return jsonEncode({'error': 'steps 需要至少一个 {goal}。请重发完整计划。'});
    }
    final ok = session.setPlan(analysis, goals);
    return jsonEncode({
      'status': 'planned',
      'analysis': analysis,
      'steps': session.map(),
      'next': session.nextStep?.toMap(),
      'instruction': '按计划逐步推进：完成一步调 solve_finish_step；'
          '方向错了调 solve_replan（预算 ${session.maxReplans} 次）。',
      if (!ok) 'error': '计划建立失败',
    });
  }
}

/// solve_finish_step：完成一步（记录结论 + 指示下一步；不许跳步）。
class SolveFinishStepTool extends AgentTool {
  final SolveSession session;
  SolveFinishStepTool(this.session)
      : super(
          'solve_finish_step',
          '标记当前步骤完成并进入下一步：传步骤 id 和这一步结论的简短总结。'
              '不要跳步；不要在真正完成前标记完成。全部完成后写出最终讲解。',
          {
            'type': 'object',
            'properties': {
              'step_id': {'type': 'string', 'description': '步骤 id（如 S1）'},
              'summary': {
                'type': 'string',
                'description': '这一步结论的简短总结（记录并释放上下文）',
              },
            },
            'required': ['step_id', 'summary'],
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final stepId = args['step_id']?.toString() ?? '';
    final summary = args['summary']?.toString() ?? '';
    if (session.steps.isEmpty) {
      return jsonEncode({'error': '还没有计划。先调用 solve_plan。'});
    }
    final step = session.markDone(stepId, summary);
    if (step == null) {
      return jsonEncode({
        'error': '步骤 id 无效：$stepId。有效 id：'
            '${session.steps.map((s) => s.id).join('、')}',
      });
    }
    return jsonEncode({
      'status': 'step_done',
      'finished': step.toMap(),
      'progress': '${session.steps.where((s) => s.done).length}/${session.steps.length}',
      'next': session.nextStep?.toMap(),
      if (session.allDone) 'all_done': true,
    });
  }
}

/// solve_replan：有界方向修正（预算由引擎把守）。
class SolveReplanTool extends AgentTool {
  final SolveSession session;
  SolveReplanTool(this.session)
      : super(
          'solve_replan',
          '思路卡住或被证明走错时换计划：给出原因和新的步骤列表。'
              '有预算上限（默认 2 次），只用于真正的方向修正；预算用尽就用现有结果收尾。',
          {
            'type': 'object',
            'properties': {
              'reason': {'type': 'string', 'description': '为什么要换方向'},
              'analysis': {'type': 'string', 'description': '新思路简述'},
              'steps': {
                'type': 'array',
                'description': '新的有序步骤，每项 {"goal": "..."}',
                'items': {
                  'type': 'object',
                  'properties': {'goal': {'type': 'string'}},
                  'required': ['goal'],
                },
              },
            },
            'required': ['reason', 'analysis', 'steps'],
          },
        );

  @override
  Future<String> execute(Map<String, dynamic> args) async {
    final reason = args['reason']?.toString() ?? '';
    final analysis = args['analysis']?.toString() ?? '';
    final goals = [
      for (final s in (args['steps'] as List? ?? const []))
        (((s as Map)['goal'] ?? '') as String).trim(),
    ].where((g) => g.isNotEmpty).toList();
    if (goals.isEmpty) {
      return jsonEncode({'error': 'steps 需要至少一个 {goal}'});
    }
    final ok = session.replan(analysis, goals);
    if (!ok) {
      return jsonEncode({
        'status': 'budget_exhausted',
        'error': '重规划预算已用尽（${session.maxReplans} 次）。'
            '请基于当前已完成的步骤直接收尾作答。',
        'current_steps': session.map(),
      });
    }
    return jsonEncode({
      'status': 'replanned',
      'reason': reason,
      'replans_used': session.replans,
      'replans_left': session.maxReplans - session.replans,
      'steps': session.map(),
      'next': session.nextStep?.toMap(),
    });
  }
}

/// 组装三件套（同一 session 实例驱动）。
Map<String, AgentTool> buildSolveTools(SolveSession session) => {
      'solve_plan': SolvePlanTool(session),
      'solve_finish_step': SolveFinishStepTool(session),
      'solve_replan': SolveReplanTool(session),
    };
