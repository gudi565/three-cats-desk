import 'dart:async';
import 'dart:convert';

import 'agent_events.dart';
import 'llm_client.dart';

/// 考研智能体 agent 循环（架构方案 v2 P1-1，2026-08-15）。
///
/// Anthropic 工程文章的朴素形态（深研验证）："LLM 在循环里调工具，
/// 显式停止条件，不上重框架"。每轮：模型 → 要工具？执行回喂 → 下一轮；
/// 不要工具 = 最终回答，done。
///
/// 停止条件：模型不再调工具 / 达 maxIterations / 超时 / 异常。
/// 事件流驱动 UI（AgentEvent）。
class AgentLoop {
  final LlmClient llm;

  /// 显式停止条件（防失控循环）。
  final int maxIterations;

  AgentLoop({LlmClient? llm, this.maxIterations = 12}) : llm = llm ?? LlmClient();

  /// 跑一轮对话。每步 yield AgentEvent；最后必发 AgentDone 或 AgentError。
  ///
  /// [systemPrompt] 猫人设+考研语境。
  /// [userMessage] 用户这轮的话。
  /// [tools] 工具集（name→执行器）。
  /// [history] 之前的对话（OpenAI messages 格式，可选）。
  Stream<AgentEvent> run({
    required String baseUrl,
    required String model,
    required String apiKey,
    required String systemPrompt,
    required String userMessage,
    Map<String, AgentTool> tools = const {},
    List<Map<String, dynamic>> history = const [],
  }) async* {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      ...history,
      {'role': 'user', 'content': userMessage},
    ];
    final toolDecls = [
      for (final t in tools.values)
        {
          'type': 'function',
          'function': {
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          }
        }
    ];

    for (var iter = 1; iter <= maxIterations; iter++) {
      yield AgentTurnStart(iter);
      final LlmResponse resp;
      try {
        resp = await llm.chat(
          baseUrl: baseUrl,
          model: model,
          apiKey: apiKey,
          messages: messages,
          tools: toolDecls,
        );
      } on TimeoutException {
        yield AgentError('模型响应超时，请稍后再试（或换更小的模型）');
        return;
      } on LlmException catch (e) {
        yield AgentError(e.message);
        return;
      } catch (e) {
        yield AgentError('连接模型失败：$e');
        return;
      }

      if (resp.content.isNotEmpty) {
        yield AgentText(resp.content);
      }

      if (!resp.wantsTool) {
        yield AgentDone(resp.content);
        return;
      }

      // 记录 assistant 的 tool_calls 消息（OpenAI 协议要求回喂前带上）
      messages.add({
        'role': 'assistant',
        'content': resp.content,
        'tool_calls': [
          for (final c in resp.toolCalls)
            {
              'id': c.id,
              'type': 'function',
              'function': {'name': c.name, 'arguments': jsonEncode(c.args)},
            }
        ],
      });

      // 逐个执行工具（串行，考研工具全是本地读，无并发需求）
      for (final call in resp.toolCalls) {
        yield AgentToolCall(call.name, call.args);
        final tool = tools[call.name];
        String result;
        if (tool == null) {
          result = jsonEncode({'error': '未知工具 $call.name'});
        } else {
          try {
            result = await tool.execute(call.args);
          } catch (e) {
            result = jsonEncode({'error': '工具执行失败: $e'}); // 工具失败不杀循环
          }
        }
        yield AgentToolResult(call.name, result);
        messages.add({
          'role': 'tool',
          'tool_call_id': call.id,
          'content': result,
        });
      }
    }

    yield AgentError('达到最大推理轮数（$maxIterations），请换个更具体的问题');
  }
}

/// 智能体工具抽象。
///
/// 深研结论："工具定义值得和系统提示词同等的打磨投入"——
/// [description] 和 [parameters]（JSON Schema）就是给模型看的 prompt，
/// 要写清楚什么时候用、参数什么含义。
abstract class AgentTool {
  final String name;
  final String description;
  final Map<String, dynamic> parameters; // JSON Schema

  const AgentTool(this.name, this.description, this.parameters);

  /// 执行并返回喂给模型的文本（通常 JSON）。
  Future<String> execute(Map<String, dynamic> args);
}
