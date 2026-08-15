import 'dart:async';
import 'dart:convert';

import 'agent_events.dart';
import 'llm_client.dart';

/// 考研智能体 agent 循环（P1-1 建立，2026-08-15 DT1 深读 DeepTutor 后升级收尾鲁棒性）。
///
/// Anthropic 朴素形态 + DeepTutor 四防线：
///   ① 预算耗尽 → 不硬报错：注入 finish_exhausted 指令 + 不带 tools 强制收尾
///     （settlement 思想：让模型基于已收集材料作答，而非丢弃）
///   ② 空答（只推理没回答）→ 一次性 finish_empty_nudge 催促（防死循环）
///   ③ finishReason=length → continue_truncated 续写（不重复已有内容）
///   ④ 中途异常且已有材料（iter>0）→ forced_finish 抢救而非直接报错
class AgentLoop {
  final LlmClient llm;

  /// 显式停止条件（防失控循环）。
  final int maxIterations;

  AgentLoop({LlmClient? llm, this.maxIterations = 12}) : llm = llm ?? LlmClient();

  /// 跑一轮对话。每步 yield AgentEvent；最后必发 AgentDone 或 AgentError。
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

    var nudged = false; // 空答只催一次
    final collected = StringBuffer(); // 已产出的正文（forced_finish 兜底用）

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
        // ④ 中途超时但已有材料 → 抢救
        if (iter > 1 && collected.isNotEmpty) {
          yield* _forcedFinish(baseUrl, model, apiKey, messages, collected);
        } else {
          yield AgentError('模型响应超时，请稍后再试（或换更小的模型）');
        }
        return;
      } on LlmException catch (e) {
        if (iter > 1 && collected.isNotEmpty) {
          yield AgentLog('模型异常，基于已收集材料收尾：$e');
          yield* _forcedFinish(baseUrl, model, apiKey, messages, collected);
        } else {
          yield AgentError(e.message);
        }
        return;
      } catch (e) {
        if (iter > 1 && collected.isNotEmpty) {
          yield* _forcedFinish(baseUrl, model, apiKey, messages, collected);
        } else {
          yield AgentError('连接模型失败：$e');
        }
        return;
      }

      if (resp.reasoning.isNotEmpty) {
        yield AgentThinking(resp.reasoning);
      }
      if (resp.content.isNotEmpty) {
        collected.write(resp.content);
        yield AgentText(resp.content);
      }

      // ③ 截断续写：保留前缀，注入续写指令后继续循环（不带工具收尾调用）
      if (resp.truncated && !resp.wantsTool) {
        messages.add({'role': 'assistant', 'content': resp.content});
        messages.add({
          'role': 'user',
          'content': '你上一条回复因 token 上限而中断。请从中断处继续，'
              '不要重复已有内容，并完成面向用户的回答。',
        });
        continue;
      }

      // ② 空答 nudge：只推理没回答也没调工具 → 催一次
      if (!resp.wantsTool && resp.content.isEmpty && !nudged) {
        nudged = true;
        messages.add({
          'role': 'user',
          'content': '你上一轮只输出了内部推理——既没有调用工具，也没有写出面向用户的回答。'
              '现在继续：要么调用工具执行你计划好的步骤，要么直接写出最终回答。',
        });
        continue;
      }

      if (!resp.wantsTool) {
        yield AgentDone(resp.content.isEmpty ? collected.toString() : resp.content);
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

      // 逐个执行工具（串行）+ 防错闸（DT3）：
      //   必填参数缺失 → 不执行，错误信息即纠正 prompt 回喂
      //   同批重复调用 → 跳过回喂提示
      final seenCalls = <String>{};
      for (final call in resp.toolCalls) {
        yield AgentToolCall(call.name, call.args);
        final tool = tools[call.name];
        String result;
        if (tool == null) {
          result = jsonEncode({
            'error': '未知工具 $call.name。可用工具：${tools.keys.join('、')}',
          });
        } else {
          final missing = _missingRequired(tool, call.args);
          final dedupeKey = '${call.name}:${_stableJson(call.args)}';
          if (missing != null) {
            result = jsonEncode({
              'error': '调用 ${call.name} 缺少必填参数：$missing。'
                  '请补全参数后原样重发（不补全会再次被拒）。',
            });
          } else if (seenCalls.contains(dedupeKey)) {
            result = jsonEncode({
              'error': '重复的并行调用已跳过（见前一个同参数结果）。'
                  '同一条消息里的并行调用参数必须不同。',
            });
          } else {
            seenCalls.add(dedupeKey);
            try {
              result = await tool.execute(call.args);
            } catch (e) {
              // 工具失败不杀循环：错误作为结果回喂，模型可换路
              result = jsonEncode({'error': '工具执行失败: $e'});
            }
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

    // ① 预算耗尽 → settlement：注入指令 + 不带 tools 强制收尾
    yield const AgentLog('轮次预算已用尽，基于已收集的材料收尾');
    yield* _forcedFinish(baseUrl, model, apiKey, messages, collected);
  }

  /// 强制收尾：追加 finish_exhausted 指令，不带 tools 调一次（模型只能作答）。
  /// 失败则用已收集文本兜底，绝不让用户拿不到任何回答。
  Stream<AgentEvent> _forcedFinish(
    String baseUrl,
    String model,
    String apiKey,
    List<Map<String, dynamic>> messages,
    StringBuffer collected,
  ) async* {
    messages.add({
      'role': 'user',
      'content': '循环轮次预算已用尽，仍有缺口未补齐。现在停止调用工具，'
          '基于已有材料作答，并简短说明仍不确定的部分。',
    });
    try {
      final resp = await llm.chat(
        baseUrl: baseUrl,
        model: model,
        apiKey: apiKey,
        messages: messages,
        tools: const [], // 不带工具：模型只能收尾作答
      );
      final answer = resp.content.isNotEmpty
          ? resp.content
          : (collected.isNotEmpty ? collected.toString() : '（未能生成回答，请重试或缩小问题范围）');
      yield AgentDone(answer);
    } catch (_) {
      yield AgentDone(collected.isNotEmpty
          ? collected.toString()
          : '（收尾失败且无已收集材料，请重试）');
    }
  }

  /// 必填参数预检：缺失返回描述（不执行工具，错误信息回喂即纠正）。
  String? _missingRequired(AgentTool tool, Map<String, dynamic> args) {
    final required = (tool.parameters['required'] as List?) ?? const [];
    final missing = [
      for (final r in required)
        if (args[r] == null || args[r].toString().trim().isEmpty) r.toString(),
    ];
    return missing.isEmpty ? null : missing.join('、');
  }

  String _stableJson(Map<String, dynamic> m) {
    final keys = m.keys.toList()..sort();
    return jsonEncode({for (final k in keys) k: m[k]});
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
