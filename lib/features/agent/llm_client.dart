import 'dart:convert';

import 'package:http/http.dart' as http;

/// OpenAI 兼容 LLM client（架构方案 v2 P1-1，2026-08-15）。
///
/// 一个 client 通吃智谱/DeepSeek/Ollama/LM Studio——它们都实现
/// POST {baseUrl}/chat/completions（OpenAI 兼容），差异只在 baseUrl/model/key。
///
/// **非流式起步**（深研高危预警①：流式 tool-call 分片拼接各家语义不一、
/// 拼错=静默失败；首版 stream=false，可靠优先。流式等真实需求出现再上）。
///
/// 工具调用用 OpenAI tools 格式（function declarations + tool_calls 响应）。
/// 智谱 GLM-4.7 与 Ollama 的 tools 支持均兼容此格式。
class LlmClient {
  final http.Client _http;
  final Duration timeout;

  LlmClient({http.Client? client, this.timeout = const Duration(seconds: 120)})
      : _http = client ?? http.Client();

  /// 一轮对话调用。
  ///
  /// [messages] OpenAI 格式：system/user/assistant/tool 历史。
  /// [tools] 工具声明（OpenAI function 格式；空=不带工具）。
  /// 返回 [LlmResponse]：文本 与/或 工具调用列表。
  Future<LlmResponse> chat({
    required String baseUrl,
    required String model,
    required String apiKey,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools = const [],
  }) async {
    final uri = Uri.parse(baseUrl.endsWith('/') ? '${baseUrl}chat/completions' : '$baseUrl/chat/completions');
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
    };
    final res = await _http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode(body),
    ).timeout(timeout);

    if (res.statusCode != 200) {
      throw LlmException('LLM 服务返回 ${res.statusCode}: ${_brief(res.body)}');
    }
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choice = (data['choices'] as List?)?.firstOrNull as Map<String, dynamic>?;
    if (choice == null) throw LlmException('LLM 响应缺 choices');
    final msg = (choice['message'] ?? const {}) as Map<String, dynamic>;
    final rawContent = (msg['content'] ?? '').toString();
    // reasoning 模型（GLM 深思/DeepSeek-R1 等）走 OpenAI 兼容必带 <think> 标签
    // 或 reasoning_content 字段——思考与作答分离（DeepTutor InlineThinkFilter 同款）。
    final reasoning = (msg['reasoning_content'] ?? '').toString();
    final stripped = _stripThink(rawContent);
    final rawCalls = (msg['tool_calls'] as List?) ?? const [];
    final calls = <LlmToolCall>[
      for (final c in rawCalls)
        if (c is Map<String, dynamic>)
          LlmToolCall(
            id: (c['id'] ?? '').toString(),
            name: (((c['function'] ?? const {}) as Map)['name'] ?? '').toString(),
            args: _parseArgs((((c['function'] ?? const {}) as Map)['arguments'] ?? '{}').toString()),
          ),
    ];
    return LlmResponse(
      content: stripped.content,
      reasoning: reasoning.isEmpty ? stripped.think : '$reasoning\n${stripped.think}',
      toolCalls: calls,
      finishReason: (choice['finish_reason'] ?? '').toString(),
    );
  }

  /// 剥离 <think>/<thinking> 块：完成判定必须用剥离后的文本
  /// （防"只有推理没有回答"被误判为完成）。
  ({String content, String think}) _stripThink(String text) {
    final re = RegExp(r'<think(?:ing)?>\s*([\s\S]*?)</think(?:ing)?>',
        caseSensitive: false);
    final thinks = <String>[];
    final content = text.replaceAllMapped(re, (m) {
      thinks.add(m.group(1) ?? '');
      return '';
    });
    return (content: content.trim(), think: thinks.join('\n'));
  }

  /// 容错解析 arguments（模型偶发输出非严格 JSON，比如尾逗号/裸引号）。
  Map<String, dynamic> _parseArgs(String raw) {
    try {
      return jsonDecode(raw) as Map<String, dynamic>? ?? {};
    } catch (_) {
      // 常见脏格式抢救：单引号→双引号
      try {
        return jsonDecode(raw.replaceAll("'", '"')) as Map<String, dynamic>;
      } catch (_) {
        return {};
      }
    }
  }

  String _brief(String body) =>
      body.length > 200 ? body.substring(0, 200) : body;
}

/// 一轮模型响应。
class LlmResponse {
  final String content; // 剥离 think 后的正文（最终回答或叙述，可为空）
  final String reasoning; // 思考通道（<think> 块/reasoning_content；空=无）
  final List<LlmToolCall> toolCalls; // 模型请求的工具调用（空=回答完成）
  final String finishReason; // stop / tool_calls / length(max_tokens) …

  const LlmResponse({
    required this.content,
    this.reasoning = '',
    required this.toolCalls,
    this.finishReason = '',
  });

  bool get wantsTool => toolCalls.isNotEmpty;

  /// 输出因 token 上限被截断（需续写）。
  bool get truncated =>
      finishReason == 'length' || finishReason == 'max_tokens';
}

class LlmToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> args;
  const LlmToolCall({required this.id, required this.name, required this.args});
}

class LlmException implements Exception {
  final String message;
  LlmException(this.message);
  @override
  String toString() => message;
}
