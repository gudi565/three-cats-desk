import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:three_cats_desk/core/cloud_sync.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/supabase_client.dart';

/// 全局单例 providers（core 层）。

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
});

final deckImporterProvider = Provider<DeckImporter>((ref) {
  return DeckImporter(ref.watch(appDatabaseProvider));
});

final cloudSyncProvider = Provider<CloudSync>((ref) {
  return CloudSync(ref.watch(appDatabaseProvider));
});

/// 登录态（StreamProvider 监听 Supabase auth 变化；未初始化时为 null）。
final authStateProvider = StreamProvider((ref) async* {
  if (!SupabaseConfig.isInitialized) {
    yield null;
    return;
  }
  yield* SupabaseConfig.client.auth.onAuthStateChange.map((e) => e.session?.user);
});
