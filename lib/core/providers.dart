import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:three_cats_desk/core/app_mode.dart';
import 'package:three_cats_desk/core/cloud_sync.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/local_only_backend.dart';
import 'package:three_cats_desk/core/supabase_client.dart';
import 'package:three_cats_desk/core/sync_backend.dart';
import 'package:three_cats_desk/core/importers/quiz_importer.dart';

/// 全局单例 providers（core 层）。

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final deckImporterProvider = Provider<DeckImporter>((ref) {
  return DeckImporter(ref.watch(appDatabaseProvider));
});

final quizImporterProvider = Provider<QuizImporter>((ref) {
  return QuizImporter(ref.watch(appDatabaseProvider));
});

/// 同步后端（按 AppMode 二选一注入，五猫业务代码零改动）：
///   - cloud 模式 → `CloudSync`（Supabase，现役行为）
///   - local 模式（默认）→ `LocalOnlyBackend`（全 no-op，本地专属系统）
/// 返回类型是抽象 `SyncBackend`，调用方不感知模式。
final cloudSyncProvider = Provider<SyncBackend>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return AppMode.isCloud ? CloudSync(db) : LocalOnlyBackend();
});

/// 登录态（StreamProvider 监听 Supabase auth 变化；本地模式/未初始化时为 null）。
final authStateProvider = StreamProvider((ref) async* {
  if (AppMode.isLocal || !SupabaseConfig.isInitialized) {
    yield null;
    return;
  }
  yield* SupabaseConfig.client.auth.onAuthStateChange.map((e) => e.session?.user);
});
