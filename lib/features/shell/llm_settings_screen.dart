import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings/settings_service.dart';
import '../../core/settings/settings_service.dart' as cfg;
import '../agent/llm_client.dart';
import '../agent/memory_curator.dart';

/// LLM 模型设置屏（P2-3）。
///
/// baseUrl/model 非敏感明文展示；API Key 密文输入（存 OS 钥匙串，见 SettingsService）。
/// 预设快捷：智谱（默认）/ Ollama 本地 / 自定义（DeepSeek 等 OpenAI 兼容端点）。
class LlmSettingsScreen extends ConsumerStatefulWidget {
  const LlmSettingsScreen({super.key});

  @override
  ConsumerState<LlmSettingsScreen> createState() => _LlmSettingsScreenState();
}

class _LlmSettingsScreenState extends ConsumerState<LlmSettingsScreen> {
  final _baseUrl = TextEditingController();
  final _model = TextEditingController();
  final _apiKey = TextEditingController();
  bool _loading = true;
  bool _obscureKey = true;

  static const _presets = [
    ('智谱 GLM（默认，国内直连）', 'https://open.bigmodel.cn/api/paas/v4', 'glm-4.7'),
    ('Ollama 本地（免 key，需本机已装）', 'http://localhost:11434/v1', 'qwen3:8b'),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await ref.read(settingsServiceProvider).loadLlmConfig();
    _baseUrl.text = cfg.baseUrl;
    _model.text = cfg.model;
    _apiKey.text = cfg.apiKey; // 回显（本机钥匙串读出）
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  bool _curating = false;

  Future<void> _curateMemory() async {
    if (_curating) return;
    setState(() => _curating = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final cfg2 = await ref.read(cfg.settingsServiceProvider).loadLlmConfig();
      final db = ref.read(appDatabaseProvider);
      final r = await MemoryCurator(db, LlmClient())
          .curate(baseUrl: cfg2.baseUrl, model: cfg2.model, apiKey: cfg2.apiKey);
      messenger.showSnackBar(SnackBar(content: Text(r.summary)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('整理失败：$e')));
    } finally {
      if (mounted) setState(() => _curating = false);
    }
  }

  Future<void> _save() async {
    await ref.read(llmConfigProvider.notifier).save(LlmConfig(
          baseUrl: _baseUrl.text.trim(),
          model: _model.text.trim(),
          apiKey: _apiKey.text.trim(),
        ));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('✅ 已保存')));
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('模型设置')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 预设
          const Text('快捷预设', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final (label, url, model) in _presets)
            Card(
              child: ListTile(
                title: Text(label, style: const TextStyle(fontSize: 14)),
                subtitle: Text(url, style: const TextStyle(fontSize: 11)),
                trailing: const Icon(Icons.arrow_downward, size: 18),
                onTap: () => setState(() {
                  _baseUrl.text = url;
                  _model.text = model;
                }),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrl,
            decoration: const InputDecoration(
              labelText: '接口地址（OpenAI 兼容 base URL）',
              hintText: 'https://…/v1',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _model,
            decoration: const InputDecoration(
              labelText: '模型名',
              hintText: 'glm-4.7 / qwen3:8b / deepseek-chat',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKey,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'API Key（本地端点可留空）',
              border: const OutlineInputBorder(),
              helperText: '仅存在本机系统钥匙串，不上传、不进备份',
              suffixIcon: IconButton(
                icon: Icon(_obscureKey ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // 画像策展：从做题行为抽取掌握度（设置页手动触发——本地无 cron）
          OutlinedButton.icon(
            onPressed: _curating ? null : _curateMemory,
            icon: _curating
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.psychology_outlined),
            label: Text(_curating ? '整理中…' : '整理记忆（从做题行为更新掌握度画像）'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('保存'),
          ),
          const SizedBox(height: 12),
          Text(
            'Key 保存在你设备的系统安全存储（macOS 钥匙串 / Windows DPAPI / Android Keystore），'
            '换设备需重新填写。备份文件不含 Key。',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.6),
          ),
        ],
      ),
    );
  }
}
