import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import 'focus_provider.dart';

/// 暖暖专注屏：选时长 → 开始 → 倒计时 → 完成/放弃。
///
/// 猫陪伴：专注时猫在角落（呼吸），完成时猫开心。完成喂统一猫魂（intimacy+）。
/// 放弃软化：不惩罚，文案是"猫等你回来"（Forest 枯树的软化版，考研焦虑人群对惩罚敏感）。
class FocusScreen extends ConsumerWidget {
  const FocusScreen({super.key});

  static const _durations = [15, 25, 45, 60];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focus = ref.watch(focusProvider);
    final controller = ref.read(focusProvider.notifier);
    final cat = ref.watch(catProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('暖暖 · 专注')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: focus.done ? _SettledView(focus: focus, cat: cat, controller: controller)
            : Column(
                children: [
                  // 猫陪伴区（1a PixelCat API：4a 的 stage/animSeed 在 4a 分支，merge 后再接）
                  PixelCat(
                    mood: focus.running ? CatMood.thinking : cat.mood,
                    size: 96,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    focus.running ? '猫咪陪你一起专注…' : '准备好就开始吧',
                    style: TextStyle(color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 24),
                  // 时长选择（仅未开始）
                  if (!focus.running && focus.elapsedSeconds == 0)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final m in _durations)
                          ChoiceChip(
                            label: Text('$m 分钟'),
                            selected: focus.plannedMinutes == m,
                            onSelected: (_) => controller.setPlanned(m),
                          ),
                      ],
                    ),
                  const Spacer(),
                  // 倒计时大数字
                  Text(
                    _fmt(focus.remainingSeconds),
                    style: const TextStyle(fontSize: 72, fontWeight: FontWeight.w700, fontFeatures: []),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: focus.progress,
                      minHeight: 8,
                      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFFE0A458)),
                    ),
                  ),
                  const Spacer(),
                  // 控制按钮
                  _Controls(focus: focus, controller: controller),
                ],
              ),
      ),
    );
  }

  String _fmt(int s) {
    final m = (s ~/ 60).toString().padLeft(2, '0');
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }
}

class _Controls extends StatelessWidget {
  final FocusState focus;
  final FocusNotifier controller;
  const _Controls({required this.focus, required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!focus.running && focus.elapsedSeconds == 0) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE0A458),
              padding: const EdgeInsets.symmetric(vertical: 16)),
          onPressed: controller.start,
          child: const Text('开始专注', style: TextStyle(fontSize: 16)),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () async {
              await controller.giveUp();
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text('放弃'),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE0A458),
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: focus.running ? controller.pause : controller.start,
            child: Text(focus.running ? '暂停' : '继续', style: const TextStyle(fontSize: 16)),
          ),
        ),
      ],
    );
  }
}

/// 结算态：完成庆祝 / 放弃软化。
class _SettledView extends StatelessWidget {
  final FocusState focus;
  final CatState cat;
  final FocusNotifier controller;
  const _SettledView({required this.focus, required this.cat, required this.controller});

  @override
  Widget build(BuildContext context) {
    final completed = focus.done && focus.finished;
    final minutes = (focus.elapsedSeconds / 60).round();
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          PixelCat(
            mood: completed ? CatMood.happy : CatMood.idle,
            size: 110,
          ),
          const SizedBox(height: 16),
          Text(
            completed ? '专注完成！' : '这次先到这',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            completed
                ? '专注了 $minutes 分钟，猫咪+1 亲密度 ❤ ${cat.intimacy}'
                : '专注了 $minutes 分钟，猫咪等你回来～不着急',
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                onPressed: controller.reset,
                child: const Text('再来一组'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE0A458)),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
