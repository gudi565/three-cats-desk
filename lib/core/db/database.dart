import 'package:drift/drift.dart';

import 'connection_stub.dart'
    if (dart.library.io) 'connection_io.dart'
    if (dart.library.html) 'connection_web.dart';
import 'tables.dart';

part 'database.g.dart';

/// 本地 SQLite（local-first 镜像）。
///
/// Web 用 WasmDatabase（sqlite3 wasm）；安卓/iOS 用 NativeDatabase 落盘。
/// 平台连接在 connection_*.dart（条件导入，避免 dart:ffi 在 Web 静态引入）。
/// Phase0 只验证 Web + 安卓。
@DriftDatabase(tables: [LocalDecks, LocalCards])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  // ---- 词书 ----

  Future<List<LocalDeck>> getAllDecks() => select(localDecks).get();

  Future<LocalDeck?> getDeckByHash(String hash) =>
      (select(localDecks)..where((d) => d.contentHash.equals(hash)))
          .getSingleOrNull();

  Future<void> upsertDeck(LocalDecksCompanion deck) =>
      into(localDecks).insertOnConflictUpdate(deck);

  Future<void> updateDeckCardCount(String deckId, int count) =>
      (update(localDecks)..where((d) => d.id.equals(deckId)))
          .write(LocalDecksCompanion(cardCount: Value(count)));

  // ---- 卡 ----

  Future<void> insertCards(List<LocalCardsCompanion> cards) =>
      batch((b) => b.insertAllOnConflictUpdate(localCards, cards));

  Future<LocalCard?> getCardById(String id) =>
      (select(localCards)..where((c) => c.id.equals(id))).getSingleOrNull();

  /// 今日到期卡（按 due 升序）。按天对齐：due 那一天开始就算到期。
  Future<List<LocalCard>> getDueCards(String deckId, {DateTime? now}) {
    final end = now ?? DateTime.now();
    return (select(localCards)
          ..where((c) => c.deckId.equals(deckId) & c.due.isSmallerOrEqualValue(end))
          ..orderBy([(c) => OrderingTerm.asc(c.due)]))
        .get();
  }

  Future<int> countCardsInDeck(String deckId) =>
      (select(localCards)..where((c) => c.deckId.equals(deckId)))
          .get()
          .then((l) => l.length);

  Future<void> updateCardFsrs(
    String id,
    String fsrsState,
    DateTime due,
    int state, {
    required bool synced,
  }) =>
      (update(localCards)..where((c) => c.id.equals(id))).write(
        LocalCardsCompanion(
          fsrsState: Value(fsrsState),
          due: Value(due),
          state: Value(state),
          synced: Value(synced),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> markSynced(String id) =>
      (update(localCards)..where((c) => c.id.equals(id)))
          .write(const LocalCardsCompanion(synced: Value(true)));

  Future<List<LocalCard>> getUnsyncedCards() =>
      (select(localCards)..where((c) => c.synced.equals(false))).get();
}
