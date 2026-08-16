import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/features/agent/tools/solve_tools.dart';

/// Solve 三件套状态机验证（DT5）。
///
/// DeepTutor 同款铁律：引擎持有确定性状态——
/// 步骤 id 由引擎重编（不信模型）、replan 预算由引擎把守（尽则拒绝且不动原计划）、
/// finish_step 校验 id、maxSteps=12 截断。
void main() {
  test('setPlan 引擎重编步骤 id S1..Sn；超 12 步截断', () async {
    final s = SolveSession('t');
    final tool = SolvePlanTool(s);
    final r = jsonDecode(await tool.execute({
      'analysis': '讲解错题',
      'steps': [for (final g in ['a', 'b', 'c', ...List.generate(15, (i) => 'x$i')]) {'goal': g}],
    })) as Map<String, dynamic>;
    expect(r['status'], 'planned');
    expect(s.steps.length, SolveSession.maxSteps); // 18 → 12
    expect(s.steps.first.id, 'S1');
    expect(s.steps.last.id, 'S12');
  });

  test('空 steps → 错误回喂要求重发', () async {
    final tool = SolvePlanTool(SolveSession('t'));
    final r = jsonDecode(await tool.execute({'analysis': 'x', 'steps': []}));
    expect(r['error'], contains('至少一个'));
  });

  test('finish_step：记录总结→进度→next；无效 id 枚举合法值', () async {
    final s = SolveSession('t')..setPlan('a', ['g1', 'g2']);
    final fin = SolveFinishStepTool(s);
    final ok = jsonDecode(await fin.execute({'step_id': 'S1', 'summary': '查了考纲'}));
    expect(ok['status'], 'step_done');
    expect(ok['progress'], '1/2');
    expect((ok['next'] as Map)['id'], 'S2');
    expect(ok.containsKey('all_done'), isFalse);

    final bad = jsonDecode(await fin.execute({'step_id': 'X9', 'summary': ''}));
    expect(bad['error'], contains('S1、S2')); // 枚举合法 id

    // 无计划时 finish → 提示先 plan
    final noPlan = jsonDecode(await SolveFinishStepTool(SolveSession('t2')).execute({'step_id': 'S1', 'summary': ''}));
    expect(noPlan['error'], contains('solve_plan'));
  });

  test('replan 预算由引擎把守：第 3 次拒绝且原计划不动', () async {
    final s = SolveSession('t', maxReplans: 2)..setPlan('a', ['旧1']);
    final rp = SolveReplanTool(s);
    expect((jsonDecode(await rp.execute({'reason': 'r', 'analysis': 'n', 'steps': [
      {'goal': '新1'}, {'goal': '新2'}]})) as Map)['status'], 'replanned');
    expect(s.steps.map((x) => x.goal).toList(), ['新1', '新2']); // 第1次已换
    // 第2次（预算内最后一个）：成功
    expect((jsonDecode(await rp.execute({'reason': 'r', 'analysis': 'n2', 'steps': [
      {'goal': '再换'}]})) as Map)['status'], 'replanned');
    expect(s.steps.map((x) => x.goal).toList(), ['再换']);
    // 第3次：预算尽拒绝且原计划不动
    final r3 = jsonDecode(await rp.execute({'reason': 'r', 'analysis': 'n3', 'steps': [
      {'goal': '不该生效'}]})) as Map<String, dynamic>;
    expect(r3['status'], 'budget_exhausted');
    expect(s.steps.map((x) => x.goal).toList(), ['再换']); // 原计划未动
    expect(r3['error'], contains('收尾'));
  });

  test('allDone 闭环 + nextStep null', () async {
    final s = SolveSession('t')..setPlan('a', ['g1']);
    await SolveFinishStepTool(s).execute({'step_id': 'S1', 'summary': '完'});
    expect(s.allDone, isTrue);
    expect(s.nextStep, isNull);
  });
}
