import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/supabase_client.dart';

/// 云同步：本地 drift（local-first）→ Supabase cards 表（异步上云）。
///
/// 契约（对齐 b1产出/schema/11-cards.sql）：
///   列：id/user_id/deck_id/type/front/back/source_app/fsrs_state(jsonb)/created_at/updated_at
///   source_app 固定 'niannian'；RLS 要求 user_id = auth.uid()。
///   fsrs_state jsonb 含 stability/difficulty/retrievability/state/reps/lapses/last_review/due。
///
/// local-first 铁律：未登录 / 未初始化 / 网络失败 → 静默跳过，本地 drift 不破，synced=false 待重试。
class CloudSync {
  final AppDatabase db;
  CloudSync(this.db);

  bool get _canSync => SupabaseConfig.isInitialized && SupabaseConfig.isLoggedIn;

  /// 评分后上云一张卡。成功返回 true 并标记 synced。
  Future<bool> pushCard(LocalCard card, FsrsCard fsrs) async {
    if (!_canSync) return false;
    try {
      await SupabaseConfig.client.from('cards').upsert({
        'id': card.id,
        'user_id': SupabaseConfig.currentUser!.id,
        'deck_id': card.deckId,
        'type': card.type,
        'front': card.front,
        'back': card.back,
        'source_app': 'niannian',
        'fsrs_state': fsrs.toJson(),
        'updated_at': DateTime.now().toIso8601String(),
      });
      await db.markSynced(card.id);
      return true;
    } on PostgrestException {
      return false; // RLS/约束拒绝等 → 本地仍存，synced=false
    } catch (_) {
      return false; // 网络等
    }
  }

  /// 重试所有未同步卡（登录后 / 网络恢复时调用）。
  Future<int> pushAllUnsynced() async {
    if (!_canSync) return 0;
    final unsynced = await db.getUnsyncedCards();
    var ok = 0;
    for (final card in unsynced) {
      final fsrs = FsrsCard.fromJson(
          jsonDecode(card.fsrsState) as Map<String, dynamic>);
      if (await pushCard(card, fsrs)) ok++;
    }
    return ok;
  }

  /// 从云拉回某词书的卡（换设备/刷新后恢复）。按 id 合并到本地。
  ///
  /// 只拉回 source_app=niannian 且 deckId 匹配的卡。Phase0 验证 cloud sync 至少 PUSH 通，
  /// 这里是 PULL 的最小实现：远端行覆盖/补齐本地（按 updated_at 较新者胜）。
  Future<int> pullDeck(String deckId) async {
    if (!_canSync) return 0;
    try {
      final rows = await SupabaseConfig.client
          .from('cards')
          .select()
          .eq('deck_id', deckId)
          .eq('source_app', 'niannian');
      var count = 0;
      for (final row in rows) {
        final fsrsJson = row['fsrs_state'] as Map<String, dynamic>?;
        if (fsrsJson == null) continue;
        final fsrs = FsrsCard.fromJson(fsrsJson);
        await db.into(db.localCards).insertOnConflictUpdate(
              LocalCardsCompanion(
                id: Value(row['id'] as String),
                deckId: Value(deckId),
                type: Value((row['type'] as String?) ?? 'qa'),
                front: Value((row['front'] as String?) ?? ''),
                back: Value(row['back'] as String?),
                sourceApp: const Value('niannian'),
                fsrsState: Value(jsonEncode(fsrsJson)),
                due: Value(fsrs.due),
                state: Value(fsrs.state.value),
                synced: const Value(true),
                updatedAt: Value(DateTime.now()),
              ),
            );
        count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }
}
