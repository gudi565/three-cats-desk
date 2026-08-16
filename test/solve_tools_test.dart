import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/features/agent/tools/solve_tools.dart';

/// Solve 三件套状态机验证（DT5，DeepTutor SolveSession 同款语义）。
///
/// 钉死：计划建立（引擎重编 S1..Sn/上限 12 步）、finish（无效 id 枚举/进度/all_done）、
/// replan 预算门（预算尽不动原计划）、空计划拒绝、步骤 id 不信模型。
void main() {
  test('plan：引擎重编 S1..Sn + 截断 12 步上限', () async {
    final s = SolveSession('t');
    final plan = SolvePlanTool(s);
    final r = jsonDecode(await plan.execute({
      'analysis': '分析',
      'steps': [for (var i = 0; i < 20; i++) {'goal': '步骤$i'}],
    })) as Map<String, dynamic>;
    expect(r['status'], 'planned');
    expect(s.steps.length, SolveSession.maxSteps); // 12 上限
    expect(s.steps.first.id, 'S1');
    expect(s.steps.last.id, 'S12'); // id 引擎编，不信模型
  });

  test('finish：完成步骤/进度/无效 id 枚举合法值/all_done', () async {
    final s = SolveSession('t')..setPlan('a', ['查错题', '讲原理']);
    final finish = SolveFinishStepTool(s);
    final r1 = jsonDecode(
        await finish.execute({'step_id': 'S1', 'summary': '查到2道'})) as Map<String, dynamic>;
    expect(r1['status'], 'step_done');
    expect(r1['progress'], '1/2');
    expect(r1['next'], {'id': 'S2', 'goal': '讲原理', 'done': false});
    expect(r1.containsKey('all_done'), isFalse);

    final bad = jsonDecode(await finish.execute({'step_id': 'S9', 'summary': 'x'})) as Map<String, dynamic>;
    expect(bad['error'], contains('S1、S2')); // 枚举合法 id 教模型改对

    final r2 = jsonDecode(
        await finish.execute({'step_id': 'S2', 'summary': '讲完'})) as Map<String, dynamic>;
    expect(r2['all_done'], true);
  });

  test('replan：预算门——用尽后拒绝且不动原计划', () async {
    final s = SolveSession('t', maxReplans: 2)..setPlan('a', ['旧1', '旧2']);
    s.markDone('S1', '完成了一半');
    final replan = SolveReplanTool(s);

    final r1 = jsonDecode(await replan.execute(
        {'reason': 'r', 'analysis': '新', 'steps': [
          {'goal': '新1'}, {'goal': '新2'}, {'goal': '新3'}]})) as Map<String, dynamic>;
    expect(r1['status'], 'replanned');
    expect(r1['replans_left'], 1);
    expect(s.steps.length, 3); // 新计划生效
    expect(s.steps.every((st) => !st.done), isTrue); // 重规划后全部重来

    // 预算 2：第二次 replan 仍成功（replans_left=0）
    final r2 = jsonDecode(await replan.execute(
        {'reason': 'r2', 'analysis': '再新', 'steps': [
          {'goal': 'y'}]})) as Map<String, dynamic>;
    expect(r2['status'], 'replanned');
    expect(r2['replans_left'], 0);

    // 第三次 → 预算尽，且原计划不动
    final r3 = jsonDecode(await replan.execute(
        {'reason': 'r3', 'analysis': '第三次', 'steps': [
          {'goal': 'z'}]})) as Map<String, dynamic>;
    expect(r3['status'], 'budget_exhausted');
    expect(s.steps.length, 1); // 保持第二次的计划
    expect(s.steps.first.goal, 'y');
  });

  test('finish 无计划 → 提示先 solve_plan；plan 空 steps → 拒绝', () async {
    final s = SolveSession('t');
    final finish = SolveFinishStepTool(s);
    final r = jsonDecode(
        await finish.execute({'step_id': 'S1', 'summary': 'x'})) as Map<String, dynamic>;
    expect(r['error'], contains('solve_plan'));

    final plan = SolvePlanTool(s);
    final empty = jsonDecode(
        await plan.execute({'analysis': 'a', 'steps': []})) as Map<String, dynamic>;
    expect(empty['error'], isNotNull);
  });
}
