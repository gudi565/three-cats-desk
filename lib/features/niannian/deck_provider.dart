import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/providers.dart';

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
