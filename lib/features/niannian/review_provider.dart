import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:three_cats_desk/core/cloud_sync.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/sync_backend.dart';
import '../cat/cat_provider.dart';
import 'package:three_cats_desk/core/deck_providers.dart';

/// 翻卡复习会话状态。
class ReviewSession {
  final List<LocalCard> queue; // 今日到期队列
  final int index;
  final bool showBack;
  final int reviewedCount;

  const ReviewSession({
    required this.queue,
    this.index = 0,
    this.showBack = false,
    this.reviewedCount = 0,
  });

  LocalCard? get current => index < queue.length ? queue[index] : null;
  bool get done => index >= queue.length;

  ReviewSession copyWith({int? index, bool? showBack, int? reviewedCount}) =>
      ReviewSession(
        queue: queue,
        index: index ?? this.index,
        showBack: showBack ?? this.showBack,
        reviewedCount: reviewedCount ?? this.reviewedCount,
      );
}

/// 翻卡 + FSRS 评分。闭环：
///   评分 → fsrs.schedule → 更新 drift（synced=false）→ 异步上云 → 成功则 markSynced。
/// 未登录跳过上云（local-first 不破）。
class ReviewController extends StateNotifier<ReviewSession> {
  final AppDatabase db;
  final SyncBackend sync;
  final String deckId;
  /// 评分成功后调（provider 层注入：自增 deckRevisionProvider → deck 列表到期数刷新）。
  final void Function()? onGraded;
  static const _fsrs = Fsrs();

  /// 评分进行中标志：防止快速连点造成重入（同一张卡被评两次 / 跳过下一张）。
  bool _grading = false;

  ReviewController(this.db, this.sync, this.deckId, {this.onGraded})
      : super(const ReviewSession(queue: [])) {
    _load();
  }

  final Set<String> _answeredNoteIds = {}; // sibling 埋卡：已答卡的 noteId 集

  Future<void> _load() async {
    final due = await db.getDueCards(deckId, excludeNoteIds: _answeredNoteIds);
    state = ReviewSession(queue: due);
  }

  void flip() {
    if (state.current != null) {
      state = state.copyWith(showBack: !state.showBack);
    }
  }

  Future<void> grade(FsrsRating rating) async {
    // 重入守卫：评分是 async（跨 db 写 + 上云），连点会读同一 current 卡 →
    // 双重排期 + 跳过下一张 + reviewedCount 虚高。第一个未完成的 grade 排斥后续。
    if (_grading) return;
    final card = state.current;
    if (card == null) return;
    _grading = true;
    try {
      // 1) FSRS 排期
      final old = FsrsCard.fromJson(jsonDecode(card.fsrsState) as Map<String, dynamic>);
      final updated = _fsrs.schedule(old, rating);
      final fsrsJson = jsonEncode(updated.toJson());

      // 2) 落 drift（synced=false 待上云）
      final newCard = card.copyWith(
        fsrsState: fsrsJson,
        due: updated.due,
        state: updated.state.value,
        synced: false,
        updatedAt: DateTime.now(),
      );
      await db.updateCardFsrs(card.id, fsrsJson, updated.due, updated.state.value, synced: false);

      // 3) 异步上云（不阻塞翻下一张；未登录/失败静默）
      unawaited(sync.pushCard(newCard, updated));

      // 4) 翻下一张（sibling 埋卡：记下 noteId，下次 _load 排除同源卡）
      if (card.noteId != null && card.noteId!.isNotEmpty) {
        _answeredNoteIds.add(card.noteId!);
      }
      state = state.copyWith(
        index: state.index + 1,
        showBack: false,
        reviewedCount: state.reviewedCount + 1,
      );
      // 5) 通知 deck 列表刷新到期数（dueCountProvider 否则会缓存旧值）。
      onGraded?.call();
    } finally {
      _grading = false;
    }
  }

  Future<void> reload() => _load();
}

final reviewControllerProvider = StateNotifierProvider.autoDispose
    .family<ReviewController, ReviewSession, String>((ref, deckId) {
  return ReviewController(
    ref.watch(appDatabaseProvider),
    ref.watch(cloudSyncProvider),
    deckId,
    onGraded: () {
      // 评分后自增修订号 → deckListProvider/dueCountProvider 重算到期数。
      ref.read(deckRevisionProvider.notifier).state++;
      // 猫养成：复习一张卡 → intimacy +1（只增路径，正反馈）。
      // fire-and-forget：猫进度失败不影响 FSRS 闭环。
      ref.read(catProvider.notifier).onCardReviewed();
    },
  );
});
