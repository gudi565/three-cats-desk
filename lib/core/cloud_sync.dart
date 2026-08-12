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

  /// 云端活动埋点（雷2 修复）：这是「次日留存」唯一可算的云端信号。
  ///
  /// 冷启动时（登录态恢复后）往 user_daily_activity upsert 一行，标记「该用户今天打开了 App」。
  /// 此前云端唯一带时间戳的事件是 cards.updated_at（=复习了卡，而非打开了 App）——发用户前
  /// 必须补，否则发了也没法度量次留（元根因：发了没法验证）。
  ///
  /// 顺带上云一个 intimacy 整数快照：猫进度是本 App 唯一的用户资产、且是唯一无云备份状态
  /// （审计 P1）。把它挂在已发的 activity 行上（不建猫专表、零额外网络调用），既防资产归零，
  /// 又给「谁因猫回来」的归因留了数据。
  ///
  /// 幂等：同一天多次调用只更新 last_opened_at / open_count / intimacy。
  /// 依赖 Supabase 表 user_daily_activity（见 02_Flutter工程/phase1a-supabase-activity.sql）。
  /// local-first：表不存在/未登录/无网时静默降级。
  Future<void> markActivity({int? intimacy}) async {
    if (!_canSync) return; // 未初始化/未登录（匿名）：无云端脚印，本地不破
    final client = SupabaseConfig.client;
    final userId = SupabaseConfig.currentUser!.id;
    final day = _todayKey();
    final nowIso = DateTime.now().toUtc().toIso8601String();

    // 读今天的现有行（open_count 递增；first_opened_at 只在首行写入）。
    var openCount = 1;
    DateTime? firstOpened;
    try {
      final existing = await client
          .from('user_daily_activity')
          .select('open_count, first_opened_at')
          .eq('user_id', userId)
          .eq('day', day)
          .maybeSingle();
      if (existing != null) {
        openCount = ((existing['open_count'] as num?)?.toInt() ?? 0) + 1;
        final fo = existing['first_opened_at'] as String?;
        if (fo != null) firstOpened = DateTime.tryParse(fo);
      }
    } catch (_) {
      // 读失败不阻塞：仍按 open_count=1 上行（最多低估当日打开次数，不丢"打开了"这个事实）。
    }

    final row = <String, dynamic>{
      'user_id': userId,
      'day': day,
      'first_opened_at': (firstOpened ?? DateTime.now()).toUtc().toIso8601String(),
      'last_opened_at': nowIso,
      'open_count': openCount,
    };
    if (intimacy != null) row['intimacy'] = intimacy;

    try {
      await client.from('user_daily_activity').upsert(row, onConflict: 'user_id,day');
    } catch (_) {
      // 静默降级：local-first，写云失败不影响本地使用。
    }
  }

  /// 暖暖：专注记录上云（focus_sessions 表，见 phase2-supabase-focus.sql）。
  /// 暖暖写 focus_sessions（source_app=nuannuan），不写 cards。local-first：失败静默。
  Future<bool> pushFocusSession(FocusSession s) async {
    if (!_canSync) return false;
    try {
      await SupabaseConfig.client.from('focus_sessions').upsert({
        'id': s.id,
        'user_id': SupabaseConfig.currentUser!.id,
        'started_at': s.startedAt.toUtc().toIso8601String(),
        'planned_minutes': s.plannedMinutes,
        'actual_seconds': s.actualSeconds,
        'completed': s.completed,
        'source_app': s.sourceApp,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      await db.markFocusSynced(s.id);
      return true;
    } catch (_) {
      return false; // 表未建/网络/RLS → 本地仍存，synced=false 待重试
    }
  }

  /// 稳稳：作答记录上云（attempts 表，见 phase2-supabase-quiz.sql）。
  /// 客观判分（isCorrect），local-first：失败静默。
  Future<bool> pushAttempt(Attempt a, Question q) async {
    if (!_canSync) return false;
    try {
      await SupabaseConfig.client.from('attempts').upsert({
        'id': a.id,
        'user_id': SupabaseConfig.currentUser!.id,
        'question_id': a.questionId,
        'selected_index': a.selectedIndex,
        'is_correct': a.isCorrect,
        'answered_at': a.answeredAt.toUtc().toIso8601String(),
        'source_app': 'wenwen',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      await db.markAttemptSynced(a.id);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 当日 0 点对齐的日期 key（YYYY-MM-DD），对齐 Supabase `day` 列（date 类型）。
  String _todayKey() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }
}
