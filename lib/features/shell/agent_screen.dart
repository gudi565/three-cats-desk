import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/profile_notifier.dart';
import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';

/// 考研智能体（主对话入口，占位——L2 接 Dart agent loop）。
///
/// 站外壳阶段（2026-08-15）只立形态：说明能做什么 + 引导语，输入框展示但提示"即将上线"。
/// 真接智能体时替换成对话流（读五猫数据当工具：错题/进度/考纲）。
class AgentScreen extends ConsumerWidget {
  const AgentScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cat = ref.watch(catProvider);
    final pack = ref.watch(contentProfileProvider);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                PixelCat(mood: cat.mood, size: 72),
                const SizedBox(height: 20),
                const Text('考研智能体',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Text(
                  '我是你的考研搭子，认识你的全部资料。\n'
                  '我可以：讲你的错题、按你的薄弱点出题、'
                  '引用你的考纲答疑、陪你规划复习。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, height: 1.7, color: Colors.grey.shade700),
                ),
                const SizedBox(height: 20),
                // 读得懂的资料预览（真实：知识库数据源）
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEAF4F7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.library_books_outlined,
                          size: 18, color: Color(0xFF3E8EAA)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '当前资料包：${pack.displayName}',
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TextField(
                  enabled: false,
                  decoration: InputDecoration(
                    hintText: '智能体即将上线，先去看看五猫吧',
                    prefixIcon: const Icon(Icons.auto_awesome_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14)),
                    filled: true,
                    fillColor: Colors.grey.shade100,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
