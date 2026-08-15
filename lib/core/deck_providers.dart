import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/database.dart';
import 'providers.dart';

/// 词书/卡数据 providers（core 层）。
///
/// 从 features/niannian/deck_provider.dart 迁入（2026-08-15 P0-1 依赖方向修正）：
/// cross_app_cards（core）需要 deckRevisionProvider，原位置造成 core→features 反向依赖。
/// 念念 UI 直接改用这里的同款 provider。

/// 词书数据修订号：评分后自增，触发 dueCountProvider/deckListProvider 重算，
/// 否则它们缓存旧值（评分把 due 推后，但 deck 列表「今日到期 N」不刷新）。
final deckRevisionProvider = StateProvider<int>((ref) => 0);

/// 词书列表（drift 本地）。启动时已由 bootstrap 导入 assets 词书。
/// watch(deckRevisionProvider) → 评分后自增 → 此 provider 重取最新。
final deckListProvider = FutureProvider<List<LocalDeck>>((ref) async {
  ref.watch(deckRevisionProvider); // 评分后失效重算
  return ref.watch(appDatabaseProvider).getAllDecks();
});

/// 某词书今日到期卡数量（deck 列表显示用）。
final dueCountProvider = FutureProvider.family<int, String>((ref, deckId) async {
  ref.watch(deckRevisionProvider); // 评分后失效重算
  final due = await ref.watch(appDatabaseProvider).getDueCards(deckId);
  return due.length;
});

/// 某词书总卡数。
final cardCountProvider = FutureProvider.family<int, String>((ref, deckId) async {
  return ref.watch(appDatabaseProvider).countCardsInDeck(deckId);
});
