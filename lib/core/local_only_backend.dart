import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/sync_backend.dart';

/// 本地专属后端（`AppMode.isLocal` 时注入）：所有云同步方法 no-op。
///
/// 这是「本地部署 + 按人定制」方向的默认后端。三猫是 local-first 架构，
/// drift 本地库是唯一真相源，所以"没有云"不是降级而是设计形态——
/// 本地行保持 `synced=false`（语义="没有远端副本"），不会丢失任何数据。
///
/// 与 `CloudSync` 的差异只有一点语义：push* 恒返回 false（"没上云"）。
/// 调用方（review_provider 等）据此**不**把卡标成 synced——这正是我们要的：
/// 若将来同一台设备切回云端版，这些 `synced=false` 的行会被 `pushAllUnsynced` 自然补齐。
class LocalOnlyBackend implements SyncBackend {
  @override
  Future<bool> pushCard(LocalCard card, FsrsCard fsrs) async => false;

  @override
  Future<bool> pushNote(Note n) async => false;

  @override
  Future<bool> pushLiterature(LiteratureData l) async => false;

  @override
  Future<bool> pushFocusSession(FocusSession s) async => false;

  @override
  Future<bool> pushAttempt(Attempt a, Question q) async => false;

  @override
  Future<int> pushAllUnsynced() async => 0;

  @override
  Future<int> pullDeck(String deckId) async => 0;

  @override
  Future<void> markActivity({int? intimacy}) async {}
}
