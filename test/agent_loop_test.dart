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

  test('达到最大迭代 → AgentError（防失控）', () async {
    // 模型永远要调工具
    final llm = mockLlm()
      ..responses = List.generate(
          10,
          (i) => LlmResponse(
              content: '',
              toolCalls: [LlmToolCall(id: 'c$i', name: 't', args: const {})]));
    final events = await AgentLoop(llm: llm, maxIterations: 3)
        .run(baseUrl: 'x', model: 'm', apiKey: 'k', systemPrompt: 's', userMessage: 'u', tools: {'t': FakeTool('t')})
        .toList();
    final err = events.whereType<AgentError>().single;
    expect(err.message, contains('最大推理轮数'));
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
