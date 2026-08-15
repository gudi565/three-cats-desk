import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/fsrs.dart';
import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import 'package:three_cats_desk/core/deck_providers.dart';
import 'login_screen.dart';
import 'review_provider.dart';

/// 词书列表（drift 本地）。点击进入翻卡。
class DeckListScreen extends ConsumerWidget {
  const DeckListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final decks = ref.watch(deckListProvider);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('念念 · 词书'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            // 用 MaterialPageRoute 直接 push（与 HomeScreen 一致），勿用 pushNamed：
            // GoRoute 只配了 path:'/login' 没 name，pushNamed 会解析失败 → 登录页进不去。
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            ),
            tooltip: '登录',
          ),
        ],
      ),
      body: decks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('还没有词书'))
            : ListView.builder(
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final d = list[i];
                  return _DeckTile(deck: d);
                },
              ),
      ),
    );
  }
}

class _DeckTile extends ConsumerWidget {
  final dynamic deck; // LocalDeck
  const _DeckTile({required this.deck});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dueCount = ref.watch(dueCountProvider(deck.id)).value ?? 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Color(0xFF000000 | deck.accentHex),
          child: Text(deck.name.isNotEmpty ? deck.name[0] : '📖',
              style: const TextStyle(color: Colors.white)),
        ),
        title: Text(deck.name),
        subtitle: Text('${deck.cardCount} 张卡 · 今日到期 $dueCount'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ReviewScreen(deckId: deck.id, deckName: deck.name)),
        ),
      ),
    );
  }
}

/// 翻卡屏：正面 → 点翻面 → 4 键 FSRS 评分。顶部猫进度条（Phase 1a 养成 hook）。
class ReviewScreen extends ConsumerWidget {
  final String deckId;
  final String deckName;
  const ReviewScreen({super.key, required this.deckId, required this.deckName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(reviewControllerProvider(deckId));
    final controller = ref.read(reviewControllerProvider(deckId).notifier);

    return Scaffold(
      appBar: AppBar(title: Text(deckName)),
      body: session.done
          ? _DoneView(reviewedCount: session.reviewedCount)
          : session.current == null
              ? const Center(child: Text('今日无到期卡'))
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _CatBar(
                        index: session.index,
                        total: session.queue.length,
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: _CardView(session: session, controller: controller),
                      ),
                      const SizedBox(height: 12),
                      _GradeBar(session: session, controller: controller),
                    ],
                  ),
                ),
    );
  }
}

/// 顶部猫进度条：像素猫 + 心情 + 亲密度 + 今日 N/M 进度。
/// 这是 1a 核心视觉——用户每翻一张都能看到猫在变。
class _CatBar extends ConsumerWidget {
  final int index;
  final int total;
  const _CatBar({required this.index, required this.total});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cat = ref.watch(catProvider);
    final mood = cat.mood;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // 猫心情用 AnimatedSwitcher：评分后 mood 变 → 淡入淡出。
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: PixelCat(
              key: ValueKey(mood),
              mood: mood,
              size: 52,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      mood.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // 亲密度数字用 AnimatedSwitcher 跳动。
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.4),
                          end: Offset.zero,
                        ).animate(anim),
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: Text(
                        '❤ ${cat.intimacy}',
                        key: ValueKey(cat.intimacy),
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFFE0506E),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                // 今日进度条。
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: total == 0 ? 0 : (index / total),
                    minHeight: 6,
                    backgroundColor: Theme.of(context).colorScheme.surface,
                    valueColor: AlwaysStoppedAnimation(Color(0xFF3E8EAA)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '今日 $index / $total',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 完成态：猫庆祝 + 今日复习数 + 一句亲密反馈。
class _DoneView extends ConsumerWidget {
  final int reviewedCount;
  const _DoneView({required this.reviewedCount});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cat = ref.watch(catProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            PixelCat(mood: cat.mood, size: 120),
            const SizedBox(height: 16),
            const Text('今日复习完成！', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('复习了 $reviewedCount 张卡', style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFCE8EC),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _bondMessage(cat.intimacy),
                style: const TextStyle(color: Color(0xFFC0455F)),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text('返回词书'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 亲密度对应的反馈语——给「为了猫明天再打开」一个情感锚点。
  String _bondMessage(int intimacy) {
    if (intimacy <= 0) return '🐱 和你的猫刚认识～明天再来看看它吧';
    if (intimacy < 3) return '🐱 猫咪开始记住你了，明天见！';
    if (intimacy < 8) return '🐱 猫咪越来越喜欢你了～';
    if (intimacy < 20) return '🐱 你的猫在等你明天回来复习！';
    return '🐱 猫咪已经离不开你了，继续保持～';
  }
}

/// 卡面：正面/翻面。进度与评分拆到 _CatBar / _GradeBar。
class _CardView extends StatelessWidget {
  final dynamic session;
  final dynamic controller;
  const _CardView({required this.session, required this.controller});

  @override
  Widget build(BuildContext context) {
    final card = session.current!;
    final fsrs = FsrsCard.fromJson(jsonDecode(card.fsrsState) as Map<String, dynamic>);
    final isNew = fsrs.state == FsrsState.newCard;

    return GestureDetector(
      onTap: controller.flip,
      child: Card(
        elevation: 2,
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      card.front,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                    if (session.showBack) ...[
                      const Divider(height: 32),
                      Text(
                        card.back ?? '',
                        style: const TextStyle(fontSize: 17, height: 1.5),
                        textAlign: TextAlign.center,
                      ),
                    ] else ...[
                      const SizedBox(height: 28),
                      const Text('点按卡片翻面', style: TextStyle(color: Colors.grey)),
                    ],
                  ],
                ),
              ),
            ),
            // 左上角新卡/复习标记。
            Positioned(
              top: 10,
              left: 12,
              child: Chip(
                label: Text(isNew ? '新卡' : '复习', style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部评分条：未翻面显「显示答案」，翻面后显 4 键 FSRS 评分。
class _GradeBar extends StatelessWidget {
  final dynamic session;
  final dynamic controller;
  const _GradeBar({required this.session, required this.controller});

  @override
  Widget build(BuildContext context) {
    if (!session.showBack) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.tonal(
          onPressed: controller.flip,
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Text('显示答案'),
          ),
        ),
      );
    }
    return Row(
      children: [
        for (final r in FsrsRating.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _ratingColor(r),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => controller.grade(r),
                child: Text(r.label, style: const TextStyle(fontSize: 13)),
              ),
            ),
          ),
      ],
    );
  }

  Color _ratingColor(FsrsRating r) {
    switch (r) {
      case FsrsRating.again:
        return const Color(0xFFD64545);
      case FsrsRating.hard:
        return const Color(0xFFE0A458);
      case FsrsRating.good:
        return const Color(0xFF5B9E6F);
      case FsrsRating.easy:
        return const Color(0xFF4A8FA8);
    }
  }
}
