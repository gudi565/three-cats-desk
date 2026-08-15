import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/features/agent/agent_events.dart';
import 'package:three_cats_desk/features/agent/agent_loop.dart';
import 'package:three_cats_desk/features/agent/llm_client.dart';

/// Agent 循环行为验证（P1-1，mock LLM 不依赖网络）。
///
/// 钉死：工具调用回喂闭环、无工具直接 done、最大迭代停止、
/// 超时/HTTP 错误转 AgentError、工具异常不杀循环。
void main() {
  dt1Tests();
  // 假 LLM：脚本化逐轮返回
  MockLlm mockLlm() => MockLlm();

  test('模型先调工具再作答：事件序列 turn→toolCall→toolResult→done', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(
            content: '我查一下你的错题',
            toolCalls: [LlmToolCall(id: 'c1', name: 'wrong_questions', args: {})]),
        const LlmResponse(content: '你昨天错了 2 道马原题，主要是矛盾观部分', toolCalls: []),
      ];
    final loop = AgentLoop(llm: llm, maxIterations: 5);
    final events = await loop
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: '我错什么了', tools: {
          'wrong_questions': FakeTool('wrong_questions'),
        })
        .toList();

    final kinds = events.map((e) => e.runtimeType).toList();
    expect(kinds, containsAllInOrder([
      AgentTurnStart, AgentText, AgentToolCall, AgentToolResult, AgentDone
    ]));
    final done = events.whereType<AgentDone>().single;
    expect(done.answer, contains('马原'));
    // 第二轮模型收到的 messages 含工具结果回喂
    final secondCall = llm.captured[1];
    final toolMsg = secondCall.messages.where((m) => m['role'] == 'tool').single;
    expect(toolMsg['tool_call_id'], 'c1');
    expect(toolMsg['content'], contains('矛盾'));
  });

  test('模型不调工具：直接 done', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(content: '加油！', toolCalls: []),
      ];
    final events = await loopOf(llm).toList();
    expect(events.whereType<AgentDone>().single.answer, '加油！');
    expect(events.whereType<AgentToolCall>(), isEmpty);
  });

  test('达到最大迭代 → 强制收尾（DT1 新语义，不再硬报错）', () async {
    // 模型永远要调工具，收尾那次给答案
    final llm = mockLlm()
      ..responses = [
        for (var i = 0; i < 3; i++)
          LlmResponse(
              content: '',
              toolCalls: [LlmToolCall(id: 'c$i', name: 't', args: const {})]),
        const LlmResponse(content: '已尽力收集，基于现有材料回答', toolCalls: []),
      ];
    final events = await AgentLoop(llm: llm, maxIterations: 3)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {'t': FakeTool('t')})
        .toList();
    expect(events.whereType<AgentError>(), isEmpty);
    expect(events.whereType<AgentDone>().single.answer, contains('现有材料'));
  });

  test('工具抛异常不杀循环：错误作为结果回喂', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(
            content: '', toolCalls: [LlmToolCall(id: 'c1', name: 'boom', args: {})]),
        const LlmResponse(content: '工具坏了但我还活着', toolCalls: []),
      ];
    final events = await AgentLoop(llm: llm)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {
          'boom': _BoomTool(),
        })
        .toList();
    expect(events.whereType<AgentDone>().single.answer, '工具坏了但我还活着');
    final tr = events.whereType<AgentToolResult>().single;
    expect(tr.result, contains('工具执行失败'));
  });

  test('HTTP 非 200 → AgentError（可读错误）', () async {
    final llm = MockLlm()
      ..error = LlmException('LLM 服务返回 401: invalid api key');
    final events = await loopOf(llm).toList();
    expect(events.whereType<AgentError>().single.message, contains('401'));
  });

  test('未知工具名 → 错误结果回喂（不杀循环）', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(
            content: '', toolCalls: [LlmToolCall(id: 'c1', name: '不存在', args: {})]),
        const LlmResponse(content: 'ok', toolCalls: []),
      ];
    final events = await loopOf(llm).toList();
    expect(events.whereType<AgentToolResult>().single.result, contains('未知工具'));
    expect(events.whereType<AgentDone>(), isNotEmpty);
  });
}

Stream<AgentEvent> loopOf(LlmClient llm) => AgentLoop(llm: llm).run(
    baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u');

class FakeTool extends AgentTool {
  FakeTool(String name)
      : super(name, '查错题', {'type': 'object', 'properties': {}});

  @override
  Future<String> execute(Map<String, dynamic> args) async =>
      jsonEncode({'wrong': 2, 'topic': '矛盾观'});
}

class _BoomTool extends AgentTool {
  _BoomTool() : super('boom', '炸', {'type': 'object'});
  @override
  Future<String> execute(Map<String, dynamic> args) async => throw StateError('kaboom');
}

/// 脚本化假 LLM：按序返回预设响应；记录每轮收到的 messages。
/// 继承（非 implements）避免实现私有字段。
class MockLlm extends LlmClient {
  List<LlmResponse> responses = [];
  List<_Captured> captured = [];
  Object? error;

  @override
  Future<LlmResponse> chat({
    required String baseUrl,
    required String model,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    captured.add(_Captured(List.of(messages)));
    if (error != null) throw error!;
    if (responses.isEmpty) throw StateError('MockLlm 响应耗尽');
    return responses.removeAt(0);
  }
}

class _Captured {
  final List<Map<String, dynamic>> messages;
  _Captured(this.messages);
}

// ── DT1 循环收尾鲁棒四防线（顶层测试组）──
void dt1Tests() {
  MockLlm mockLlm() => MockLlm();


  test('DT1-① 预算耗尽→强制收尾产出 Done（不硬报错）', () async {
    // 模型永远要调工具，直到收尾调用（无 tools 那次）才作答
    // maxIterations=3 → 3 轮调工具后耗尽；第 4 次（forced_finish）返回答案
    final llm = mockLlm()
      ..responses = [
        for (var i = 0; i < 3; i++)
          LlmResponse(content: '', toolCalls: [LlmToolCall(id: 'c$i', name: 't', args: const {})]),
        const LlmResponse(content: '基于已查材料：答案是 X', toolCalls: []),
      ];
    final events = await AgentLoop(llm: llm, maxIterations: 3)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {'t': FakeTool('t')})
        .toList();
    final done = events.whereType<AgentDone>().single;
    expect(done.answer, contains('答案是 X'));
    expect(events.whereType<AgentError>(), isEmpty); // 不再硬报错
    // 收尾调用确实不带 tools
    final lastCall = llm.captured.last;
    expect(lastCall.messages.any((m) => m['role'] == 'user' && m['content'].toString().contains('预算已用尽')), isTrue);
  });

  test('DT1-② 空答一次性 nudge 后作答', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(content: '', toolCalls: []), // 只推理没回答
        const LlmResponse(content: '这次真的回答了', toolCalls: []),
      ];
    final events = await AgentLoop(llm: llm)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u')
        .toList();
    expect(events.whereType<AgentDone>().single.answer, '这次真的回答了');
    // nudge 指令确实注入
    final nudgeMsg = llm.captured[1].messages.where((m) => m['role'] == 'user' && m['content'].toString().contains('内部推理'));
    expect(nudgeMsg, isNotEmpty);
  });

  test('DT1-③ 截断续写：finishReason=length 注入续写指令', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(content: '前半段', toolCalls: [], finishReason: 'length'),
        const LlmResponse(content: '前半段后半段', toolCalls: [], finishReason: 'stop'),
      ];
    final events = await AgentLoop(llm: llm)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u')
        .toList();
    expect(events.whereType<AgentDone>().single.answer, contains('后半段'));
    expect(llm.captured[1].messages.any((m) => m['role'] == 'user' && m['content'].toString().contains('中断')), isTrue);
  });

  test('DT1-④ 中途异常+已有材料→forced_finish 抢救', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(content: '我查到了部分资料', toolCalls: [LlmToolCall(id: 'c1', name: 't', args: {})]),
      ];
    // 第二次 chat 抛异常，收尾调用成功
    final seq = SequentialLlm();
    seq.plans = [
      () async => const LlmResponse(content: '部分资料', toolCalls: [LlmToolCall(id: 'c1', name: 't', args: {})]),
      () async => throw LlmException('boom'),
      () async => const LlmResponse(content: '抢救成功：基于部分资料作答', toolCalls: []),
    ];
    final events = await AgentLoop(llm: seq)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {'t': FakeTool('t')})
        .toList();
    expect(events.whereType<AgentDone>().single.answer, contains('抢救成功'));
    expect(events.whereType<AgentError>(), isEmpty);
  });

  test('DT1-必填参数缺失→不执行回喂纠正', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(content: '', toolCalls: [LlmToolCall(id: 'c1', name: 'need_kw', args: {})]), // 缺 keyword
        const LlmResponse(content: '好的补全了', toolCalls: []),
      ];
    final events = await AgentLoop(llm: llm)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {
          'need_kw': _RequiredKwTool(),
        })
        .toList();
    final tr = events.whereType<AgentToolResult>().single;
    expect(tr.result, contains('缺少必填参数'));
    expect(tr.result, contains('keyword'));
    // 工具本体没被执行（结果里没有 success 字段）
    expect(tr.result.contains('ok'), isFalse);
  });

  test('DT1-同批重复调用去重回喂', () async {
    final llm = mockLlm()
      ..responses = [
        const LlmResponse(content: '', toolCalls: [
          LlmToolCall(id: 'c1', name: 't', args: {'a': 1}),
          LlmToolCall(id: 'c2', name: 't', args: {'a': 1}), // 完全相同→重复
        ]),
        const LlmResponse(content: 'done', toolCalls: []),
      ];
    final events = await AgentLoop(llm: llm)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {'t': FakeTool('t')})
        .toList();
    final results = events.whereType<AgentToolResult>().toList();
    expect(results.length, 2);
    expect(results[1].result, contains('重复'));
  });
}

/// 按计划脚本执行的假 LLM（可抛异常）。
class SequentialLlm extends LlmClient {
  List<Future<LlmResponse> Function()> plans = [];
  int _i = 0;
  @override
  Future<LlmResponse> chat({
    required String baseUrl,
    required String model,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
  }) {
    final fn = plans[_i++];
    return fn();
  }
}

class _RequiredKwTool extends AgentTool {
  _RequiredKwTool()
      : super('need_kw', '必填 keyword', {
          'type': 'object',
          'properties': {'keyword': {'type': 'string'}},
          'required': ['keyword'],
        });
  @override
  Future<String> execute(Map<String, dynamic> args) async => '{"ok": true}';
}
