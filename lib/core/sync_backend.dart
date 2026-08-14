import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';

/// 同步后端契约（本地专属版架构核心，2026-08-13）。
///
/// 背景：三猫 Flutter 从第一天就是 local-first——drift 本地库是真相源，云只是异步镜像。
/// 「本地部署 + 按人定制」方向把云整个去掉，但五猫业务代码（念念翻卡/稳稳做题/知知笔记/
/// 渊渊文献/暖暖专注/跨猫卡箱）全都通过 `cloudSyncProvider` 调这组方法。为了让它们
/// **零改动**地在两种模式下运行，把同步行为抽象成这个契约：
///
///   - `CloudSync`（Supabase 实现）：现役行为，PUSH/PULL/activity 埋点全做。
///   - `LocalOnlyBackend`（本地实现）：全部 no-op，返回「未同步」语义，本地 drift 照常。
///
/// provider 按 `AppMode.isCloud` 二选一注入。五猫只依赖本抽象，不感知模式。
///
/// 返回值语义（两个后端保持一致，调用方据此决定是否重试/标 synced）：
///   - push* 返回 true = 已持久化到远端（本地版恒 false，表示"没上云"，本地行保持 synced=false）
///   - pullDeck 返回拉回的卡数（本地版恒 0）
///   - pushAllUnsynced 返回成功上云数（本地版恒 0）
abstract class SyncBackend {
  /// 念念/跨猫卡箱：评分后上云一张卡。成功返回 true 并标记 synced。
  Future<bool> pushCard(LocalCard card, FsrsCard fsrs);

  /// 知知：笔记上云。local-first：失败静默。
  Future<bool> pushNote(Note n);

  /// 渊渊：文献上云。local-first：失败静默。
  Future<bool> pushLiterature(LiteratureData l);

  /// 暖暖：专注记录上云。local-first：失败静默。
  Future<bool> pushFocusSession(FocusSession s);

  /// 稳稳：作答记录上云（客观判分）。local-first：失败静默。
  Future<bool> pushAttempt(Attempt a, Question q);

  /// 登录后/网络恢复时重试所有未同步卡。返回成功上云数。
  Future<int> pushAllUnsynced();

  /// 从云拉回某词书的卡（换设备/刷新恢复）。返回拉回卡数。
  Future<int> pullDeck(String deckId);

  /// 留存埋点：标今日打开 + intimacy 快照。云端版写 user_daily_activity，
  /// 本地版由本地 activity_log 替代（见 activity_provider），此处 no-op。
  Future<void> markActivity({int? intimacy});
}
