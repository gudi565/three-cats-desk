/// 考研智能体事件流（架构方案 v2 P1-1，2026-08-15）。
///
/// 对标 DeepTutor 的 NDJSON 事件流（content/tool_call/tool_result/done 四类）：
/// agent loop 每一步产出 typed 事件 → UI 增量渲染 → 将来持久化为结构化块（P2-1）。
/// 非流式 LLM 起步（深研高危预警：流式 tool-call 分片解析首版不做），
/// 事件粒度 = 一轮循环一步，够 UI 用。
sealed class AgentEvent {
  const AgentEvent();
}

/// 一轮开始（模型即将被调用；iter 是当前迭代序号，从 1 起）。
class AgentTurnStart extends AgentEvent {
  final int iter;
  const AgentTurnStart(this.iter);
}

/// 模型产出的文本片段（最终回答的增量；非流式=一次性整段）。
class AgentText extends AgentEvent {
  final String text;
  const AgentText(this.text);
}

/// 思考通道（reasoning 模型的 <think> 块 / reasoning_content）。
/// UI 可折叠显示；不参与完成判定。
class AgentThinking extends AgentEvent {
  final String text;
  const AgentThinking(this.text);
}

/// 模型请求调用工具。
class AgentToolCall extends AgentEvent {
  final String name;
  final Map<String, dynamic> args;
  const AgentToolCall(this.name, this.args);
}

/// 工具执行结果（回喂给模型）。
class AgentToolResult extends AgentEvent {
  final String name;
  final String result; // JSON 字符串（喂模型用文本）
  const AgentToolResult(this.name, this.result);
}

/// 会话完成（模型给出最终回答，不再调工具）。
class AgentDone extends AgentEvent {
  final String answer;
  const AgentDone(this.answer);
}

/// 出错（网络/超时/上限）。循环终止，UI 显示可读错误。
class AgentError extends AgentEvent {
  final String message;
  const AgentError(this.message);
}

/// Agent 内部日志（调试/度量；UI 可忽略）。
class AgentLog extends AgentEvent {
  final String message;
  const AgentLog(this.message);
}
