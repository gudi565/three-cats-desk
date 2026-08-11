import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/fsrs.dart';
import 'deck_provider.dart';
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

/// 翻卡屏（简陋即可）：正面 → 点翻面 → 4 键 FSRS 评分。
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
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('🎉', style: TextStyle(fontSize: 48)),
                  const SizedBox(height: 12),
                  Text('今日复习完成 · ${session.reviewedCount} 张'),
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('返回词书'),
                  ),
                ],
              ),
            )
          : session.current == null
              ? const Center(child: Text('今日无到期卡'))
              : _CardView(session: session, controller: controller),
    );
  }
}

class _CardView extends StatelessWidget {
  final dynamic session;
  final dynamic controller;
  const _CardView({required this.session, required this.controller});

  @override
  Widget build(BuildContext context) {
    final card = session.current!;
    final fsrs = FsrsCard.fromJson(jsonDecode(card.fsrsState) as Map<String, dynamic>);
    final isNew = fsrs.state == FsrsState.newCard;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${session.index + 1} / ${session.queue.length}',
                  style: const TextStyle(color: Colors.grey)),
              Chip(
                label: Text(isNew ? '新卡' : '复习'),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 卡面
          Expanded(
            child: GestureDetector(
              onTap: controller.flip,
              child: Card(
                elevation: 2,
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          card.front,
                          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        if (session.showBack) ...[
                          const Divider(height: 32),
                          Text(
                            card.back ?? '',
                            style: const TextStyle(fontSize: 18),
                            textAlign: TextAlign.center,
                          ),
                        ] else ...[
                          const SizedBox(height: 24),
                          const Text('点按翻面', style: TextStyle(color: Colors.grey)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 4 键评分（翻面后才可评）
          if (session.showBack)
            Row(
              children: [
                for (final r in FsrsRating.values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: _ratingColor(r),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        onPressed: () => controller.grade(r),
                        child: Text(r.label),
                      ),
                    ),
                  ),
              ],
            )
          else
            FilledButton.tonal(
              onPressed: controller.flip,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                child: Text('显示答案'),
              ),
            ),
        ],
      ),
    );
  }

  Color _ratingColor(FsrsRating r) {
    switch (r) {
      case FsrsRating.again: return const Color(0xFFD64545);
      case FsrsRating.hard:  return const Color(0xFFE0A458);
      case FsrsRating.good:  return const Color(0xFF5B9E6F);
      case FsrsRating.easy:  return const Color(0xFF4A8FA8);
    }
  }
}
