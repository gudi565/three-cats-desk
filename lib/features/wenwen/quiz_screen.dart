import 'dart:convert';

import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import 'quiz_provider.dart';

/// 稳稳做题入口：选科目 → 做题 → 错题本。
class WenwenHomeScreen extends ConsumerWidget {
  const WenwenHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final questions = ref.watch(questionListProvider);
    final wrongs = ref.watch(wrongAttemptsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('稳稳 · 做题'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          questions.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('加载题库失败：$e')),
            data: (list) {
              final subjects = list.map((q) => q.subject).toSet().toList();
              if (list.isEmpty) {
                return const Center(child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Text('题库加载中…'),
                ));
              }
              return Column(
                children: [
                  for (final s in subjects)
                    Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF5B9E6F),
                          child: Text(s.isNotEmpty ? s[0] : '题',
                              style: const TextStyle(color: Colors.white)),
                        ),
                        title: Text(s),
                        subtitle: Text('${list.where((q) => q.subject == s).length} 题'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => QuizScreen(subject: s)),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          // 错题本入口
          wrongs.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (list) => Card(
              color: const Color(0xFFFFF3F0),
              child: ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFD64545),
                  child: Icon(Icons.error_outline, color: Colors.white),
                ),
                title: const Text('错题本'),
                subtitle: Text('${list.length} 道错题 · 已自动进念念复习'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const WrongBookScreen()),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 做题屏：题干 → 选项 → 判定对错 + 解析 → 下一题。
class QuizScreen extends ConsumerWidget {
  final String subject;
  const QuizScreen({super.key, required this.subject});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(quizControllerProvider(subject));
    final controller = ref.read(quizControllerProvider(subject).notifier);
    final cat = ref.watch(catProvider);

    if (session.questions.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: Text('稳稳 · $subject')),
        body: const Center(child: Text('本科目暂无题')),
      );
    }
    if (session.finished) {
      return _FinishView(session: session, cat: cat);
    }
    final q = session.current!;
    final options = (q.optionsJson.isNotEmpty)
        ? (List<String>.from((jsonDecodeSafe(q.optionsJson))))
        : <String>[];

    return Scaffold(
      appBar: AppBar(
        title: Text('$subject · ${session.index + 1}/${session.total}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: PixelCat(mood: cat.mood, size: 36)),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 题干
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(q.stem, style: const TextStyle(fontSize: 17, height: 1.5)),
              ),
            ),
            const SizedBox(height: 12),
            // 选项
            Expanded(
              child: ListView.builder(
                itemCount: options.length,
                itemBuilder: (context, i) {
                  final label = String.fromCharCode(65 + i);
                  final isSelected = session.selected == i;
                  final isAnswer = i == q.answerIndex;
                  Color? bg;
                  if (session.revealed) {
                    if (isAnswer) bg = const Color(0xFFDCF0E2);
                    else if (isSelected) bg = const Color(0xFFFADBD8);
                  } else if (isSelected) {
                    bg = Theme.of(context).colorScheme.surfaceContainerHighest;
                  }
                  return Card(
                    color: bg,
                    child: ListTile(
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: Colors.grey.shade400,
                        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
                      ),
                      title: Text(options[i]),
                      onTap: session.revealed ? null : () => controller.answer(i),
                    ),
                  );
                },
              ),
            ),
            // 判定 + 解析
            if (session.revealed) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: session.selected == q.answerIndex
                      ? const Color(0xFFDCF0E2) : const Color(0xFFFADBD8),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.selected == q.answerIndex ? '✅ 答对了' : '❌ 答错了（已进念念复习）',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if ((q.explanation ?? '').isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(q.explanation!, style: const TextStyle(fontSize: 13, height: 1.5)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: const Color(0xFF5B9E6F),
                      padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: controller.next,
                  child: Text(session.index + 1 >= session.total ? '完成' : '下一题'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<dynamic> jsonDecodeSafe(String s) {
    try { return (s.isEmpty) ? [] : (jsonDecode(s) as List); } catch (_) { return []; }
  }
}

/// 完成结算：正确率 + 猫反馈。
class _FinishView extends StatelessWidget {
  final QuizSession session;
  final CatState cat;
  const _FinishView({required this.session, required this.cat});

  @override
  Widget build(BuildContext context) {
    final total = session.total;
    final correct = session.correctCount;
    final pct = total == 0 ? 0 : (correct * 100 ~/ total);
    final wrong = total - correct;
    return Scaffold(
      appBar: AppBar(title: const Text('稳稳 · 完成')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              PixelCat(mood: cat.mood, size: 110),
              const SizedBox(height: 16),
              Text('正确率 $pct%', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('对了 $correct / $total 题' + (wrong > 0 ? '，$wrong 道错题已进念念复习' : ''),
                  style: const TextStyle(color: Colors.grey), textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text('猫咪+1 亲密度 ❤ ${cat.intimacy}', style: const TextStyle(color: Color(0xFFC0455F))),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF5B9E6F)),
                onPressed: () => Navigator.of(context).pop(),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24),
                  child: Text('返回'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 错题本：所有答错的题（新在前）。
class WrongBookScreen extends ConsumerWidget {
  const WrongBookScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wrongs = ref.watch(wrongAttemptsProvider);
    final questions = ref.watch(questionListProvider).value ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('稳稳 · 错题本')),
      body: wrongs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('还没有错题，继续保持～'))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final a = list[i];
                  final q = questions.where((x) => x.id == a.questionId).firstOrNull;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.error_outline, color: Color(0xFFD64545)),
                      title: Text(q?.stem ?? a.questionId,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      subtitle: const Text('已进念念复习队列'),
                    ),
                  );
                },
              ),
      ),
    );
  }
}
