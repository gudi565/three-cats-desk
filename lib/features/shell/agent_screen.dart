import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/settings/settings_service.dart';
import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import '../agent/chat_provider.dart';
import 'llm_settings_screen.dart';

/// 考研智能体 · 真对话屏（P2-3）。
///
/// 消息流 + 输入框 + LLM 设置入口。未配置模型 → 引导设置；
/// 智能体认识他和他的资料（工具读五猫数据），工具轨迹折叠展示。
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await ref.read(agentChatProvider.notifier).send(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(agentChatProvider);
    final cat = ref.watch(catProvider);
    _scrollToBottom();

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('考研智能体'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '模型设置',
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const LlmSettingsScreen()));
              ref.read(agentChatProvider.notifier).refreshLlmReady();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 错误横幅
          if (chat.error != null)
            Material(
              color: Colors.red.shade100,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.error_outline, color: Colors.red),
                title: Text(chat.error!, style: const TextStyle(fontSize: 13)),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => ref.read(agentChatProvider.notifier).clearError(),
                ),
              ),
            ),
          // 未配置引导
          if (!chat.llmReady)
            _SetupBanner(onOpen: () async {
              await Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LlmSettingsScreen()));
              ref.read(agentChatProvider.notifier).refreshLlmReady();
            }),
          // 消息流
          Expanded(
            child: chat.messages.isEmpty
                ? _Empty(
                    catMood: cat.mood,
                    onSample: (q) async {
                      await ref.read(agentChatProvider.notifier).send(q);
                      _scrollToBottom();
                    },
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: chat.messages.length,
                    itemBuilder: (context, i) => _bubble(chat.messages[i]),
                  ),
          ),
          // 输入区
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      enabled: !chat.running,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: chat.running ? '思考中…' : '问我错题、进度、知识点…',
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    style: IconButton.styleFrom(
                        backgroundColor: const Color(0xFF3E8EAA)),
                    onPressed: chat.running ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessageUi m) {
    final isUser = m.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF3E8EAA) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.toolTrace.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    for (final t in m.toolTrace)
                      Text(t,
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade600)),
                  ],
                ),
              ),
            Text(
              m.text.isEmpty ? '…' : m.text,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: isUser ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未配置模型引导横幅。
class _SetupBanner extends StatelessWidget {
  final Future<void> Function() onOpen;
  const _SetupBanner({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFEAF4F7),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.key, color: Color(0xFF3E8EAA)),
        title: const Text('先配置一下模型，智能体才能工作',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        subtitle: const Text('默认智谱（国内直连），填入你的 API Key 即可；也支持本地 Ollama',
            style: TextStyle(fontSize: 11)),
        trailing: FilledButton.tonal(
          onPressed: onOpen,
          child: const Text('去设置', style: TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

/// 空状态：欢迎语 + 示例问题。
class _Empty extends StatelessWidget {
  final CatMood catMood;
  final void Function(String question) onSample;
  const _Empty({required this.catMood, required this.onSample});

  static const samples = [
    '我最近错了哪些题？',
    '给我讲讲谢赫六法',
    '我今天学得怎么样？',
  ];

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PixelCat(mood: catMood, size: 64),
              const SizedBox(height: 16),
              const Text('我是你的考研搭子',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              const Text('我认识你的错题、进度和资料，\n问我任何考研相关的问题。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.6, color: Colors.grey)),
              const SizedBox(height: 20),
              for (final s in samples)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: ActionChip(
                    label: Text(s, style: const TextStyle(fontSize: 13)),
                    onPressed: () => onSample(s),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

}
