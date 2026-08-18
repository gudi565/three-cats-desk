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
@DriftDatabase(tables: [LocalDecks, LocalCards, FocusSessions, Questions, Attempts, Notes, Literature, ActivityLog, ChatMessages, MemoryEntries, LiteratureChunks])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(openConnection());
  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 9;

  /// 迁移：…v7→v8 MemoryEntries；v8→v9 LiteratureChunks。
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (migrator, from, to) async {
          if (from < 2) {
            await migrator.createTable(focusSessions);
          }
          if (from < 3) {
            await migrator.createTable(questions);
            await migrator.createTable(attempts);
          }
          if (from < 4) {
            await migrator.createTable(notes);
          }
          if (from < 5) {
            await migrator.createTable(literature);
          }
          if (from < 6) {
            await migrator.createTable(activityLog);
          }
          if (from < 7) {
            await migrator.createTable(chatMessages);
          }
          if (from < 8) {
            await migrator.createTable(memoryEntries);
          }
          if (from < 9) {
            await migrator.createTable(literatureChunks);
          }
        },
      );

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
  ///
  /// 修复（雷1）：原实现拿 `now`（含时分秒）做 `due <= now` 比较，导致「今天评 good →
  /// due 明天同一时刻」的卡，在明天同一时刻之前打开时整天不出现——次日打开队列空。
  /// 对齐 FsrsCard.isDue（fsrs.dart）：把 `now` 收敛到「今天的最后一刻」23:59:59.999，
  /// 凡是 due 在今天（含）以前的卡都到期；明天及以后的不算。
  Future<List<LocalCard>> getDueCards(String deckId, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final end = DateTime(n.year, n.month, n.day, 23, 59, 59, 999);
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

  // ---- 暖暖：专注记录 ----

  /// 插一条专注记录。
  Future<void> insertFocusSession(FocusSessionsCompanion s) =>
      into(focusSessions).insertOnConflictUpdate(s);

  /// 今日专注（startedAt 在今天 00:00 之后）。
  Future<List<FocusSession>> getTodayFocusSessions({DateTime? now}) {
    final n = now ?? DateTime.now();
    final dayStart = DateTime(n.year, n.month, n.day);
    return (select(focusSessions)
          ..where((f) => f.startedAt.isBiggerOrEqualValue(dayStart))
          ..orderBy([(f) => OrderingTerm.asc(f.startedAt)]))
        .get();
  }

  /// 未上云的专注记录（登录/网络恢复时重试）。
  Future<List<FocusSession>> getUnsyncedFocusSessions() =>
      (select(focusSessions)..where((f) => f.synced.equals(false))).get();

  Future<void> markFocusSynced(String id) =>
      (update(focusSessions)..where((f) => f.id.equals(id)))
          .write(const FocusSessionsCompanion(synced: Value(true)));

  // ---- 稳稳：题库 + 做题记录 ----

  /// 幂等插入题（按 id upsert，重复导入不重复）。
  Future<void> insertQuestions(List<QuestionsCompanion> qs) =>
      batch((b) => b.insertAllOnConflictUpdate(questions, qs));

  Future<List<Question>> getAllQuestions() =>
      (select(questions)..orderBy([(q) => OrderingTerm.asc(q.createdAt)])).get();

  Future<List<Question>> getQuestionsBySubject(String subject) =>
      (select(questions)..where((q) => q.subject.equals(subject))
            ..orderBy([(q) => OrderingTerm.asc(q.createdAt)]))
          .get();

  Future<int> countQuestions() =>
      select(questions).get().then((l) => l.length);

  /// 插一条作答记录。
  Future<void> insertAttempt(AttemptsCompanion a) =>
      into(attempts).insertOnConflictUpdate(a);

  /// 未上云的作答（登录/网络恢复重试）。
  Future<List<Attempt>> getUnsyncedAttempts() =>
      (select(attempts)..where((a) => a.synced.equals(false))).get();

  Future<void> markAttemptSynced(String id) =>
      (update(attempts)..where((a) => a.id.equals(id)))
          .write(const AttemptsCompanion(synced: Value(true)));

  /// 错题（isCorrect=false 的作答，错题本用）。
  Future<List<Attempt>> getWrongAttempts() =>
      (select(attempts)..where((a) => a.isCorrect.equals(false))
            ..orderBy([(a) => OrderingTerm.desc(a.answeredAt)]))
          .get();

  /// 今日作答数（仪表盘）。
  Future<int> getTodayAttemptCount({DateTime? now}) {
    final n = now ?? DateTime.now();
    final dayStart = DateTime(n.year, n.month, n.day);
    return (select(attempts)..where((a) => a.answeredAt.isBiggerOrEqualValue(dayStart)))
        .get().then((l) => l.length);
  }

  // ---- 知知：笔记 ----

  /// 新建/更新笔记（upsert by id）。
  Future<void> upsertNote(NotesCompanion n) =>
      into(notes).insertOnConflictUpdate(n);

  /// 所有未归档笔记（新更新在前）。
  Future<List<Note>> getNotes() =>
      (select(notes)..where((n) => n.archived.equals(false))
            ..orderBy([(n) => OrderingTerm.desc(n.updatedAt)]))
          .get();

  Future<Note?> getNoteById(String id) =>
      (select(notes)..where((n) => n.id.equals(id))).getSingleOrNull();

  Future<void> archiveNote(String id) =>
      (update(notes)..where((n) => n.id.equals(id)))
          .write(const NotesCompanion(archived: Value(true)));

  /// 未上云笔记（登录/网络恢复重试）。
  Future<List<Note>> getUnsyncedNotes() =>
      (select(notes)..where((n) => n.synced.equals(false))).get();

  Future<void> markNoteSynced(String id) =>
      (update(notes)..where((n) => n.id.equals(id)))
          .write(const NotesCompanion(synced: Value(true)));

  /// 今日更新笔记数（仪表盘）。
  Future<int> getTodayNoteCount({DateTime? now}) {
    final n = now ?? DateTime.now();
    final dayStart = DateTime(n.year, n.month, n.day);
    return (select(notes)..where((x) => x.updatedAt.isBiggerOrEqualValue(dayStart)
          & x.archived.equals(false)))
        .get().then((l) => l.length);
  }

  // ---- 渊渊：文献 ----

  /// 新建/更新文献（upsert by id）。
  Future<void> upsertLiterature(LiteratureCompanion l) =>
      into(literature).insertOnConflictUpdate(l);

  /// 按 DOI 查（检索去重：已入库的不再重复加）。
  Future<LiteratureData?> getLiteratureByDoi(String doi) =>
      (select(literature)..where((l) => l.doi.equals(doi))).getSingleOrNull();

  /// 文献库（新更新在前，未归档）。
  Future<List<LiteratureData>> getLiteratureList() =>
      (select(literature)..where((l) => l.archived.equals(false))
            ..orderBy([(l) => OrderingTerm.desc(l.updatedAt)]))
          .get();

  Future<LiteratureData?> getLiteratureById(String id) =>
      (select(literature)..where((l) => l.id.equals(id))).getSingleOrNull();

  /// 更新我的批注/摘录。
  Future<void> updateLiteratureNote(String id, String note) =>
      (update(literature)..where((l) => l.id.equals(id)))
          .write(LiteratureCompanion(note: Value(note), synced: const Value(false),
              updatedAt: Value(DateTime.now())));

  Future<void> archiveLiterature(String id) =>
      (update(literature)..where((l) => l.id.equals(id)))
          .write(const LiteratureCompanion(archived: Value(true)));

  /// 未上云文献。
  Future<List<LiteratureData>> getUnsyncedLiterature() =>
      (select(literature)..where((l) => l.synced.equals(false))).get();

  Future<void> markLiteratureSynced(String id) =>
      (update(literature)..where((l) => l.id.equals(id)))
          .write(const LiteratureCompanion(synced: Value(true)));

  // ---- 本地留存度量（activity_log，本地专属版观测仪器）----

  /// 记录一次 App 打开（upsert by day）：openCount+1、首/末次打开时间、intimacy 快照。
  /// 幂等：同一天多次调用只递增计数。本地留存度量的唯一信号源。
  Future<void> recordAppOpen(String day, {int? intimacy}) async {
    final now = DateTime.now();
    final existing = await (select(activityLog)..where((a) => a.day.equals(day)))
        .getSingleOrNull();
    if (existing == null) {
      await into(activityLog).insert(ActivityLogCompanion(
        day: Value(day),
        openCount: const Value(1),
        intimacy: Value(intimacy ?? 0),
        firstOpenedAt: Value(now),
        lastOpenedAt: Value(now),
      ));
    } else {
      await (update(activityLog)..where((a) => a.day.equals(day))).write(
        ActivityLogCompanion(
          openCount: Value(existing.openCount + 1),
          intimacy: Value(intimacy ?? existing.intimacy),
          lastOpenedAt: Value(now),
        ),
      );
    }
  }

  /// 复习一张卡后：当日 reviewed+1（ upsert 保底当天有行）。
  Future<void> recordReviewed(String day, {int? intimacy}) async {
    final existing = await (select(activityLog)..where((a) => a.day.equals(day)))
        .getSingleOrNull();
    if (existing == null) {
      await into(activityLog).insert(ActivityLogCompanion(
        day: Value(day),
        reviewed: const Value(1),
        intimacy: Value(intimacy ?? 0),
      ));
    } else {
      await (update(activityLog)..where((a) => a.day.equals(day))).write(
        ActivityLogCompanion(
          reviewed: Value(existing.reviewed + 1),
          intimacy: Value(intimacy ?? existing.intimacy),
        ),
      );
    }
  }

  /// 取最近 N 天活动（坚持仪表盘 + 诊断包导出）。
  Future<List<ActivityLogData>> getRecentActivity(int days) =>
      (select(activityLog)
            ..orderBy([(a) => OrderingTerm.desc(a.day)])
            ..limit(days))
          .get();

  /// 活跃天数（有打开记录的天数，留存计算用）。
  Future<int> countActiveDays() =>
      select(activityLog).get().then((l) => l.length);

  // ---- 智能体对话记录（chat_messages，P2-1）----

  /// 追加一条消息（id 生成在调用方——事件流边发边存）。
  Future<void> insertChatMessage(ChatMessagesCompanion m) =>
      into(chatMessages).insert(m);

  /// 某会话全部消息（时间正序）。
  Future<List<ChatMessage>> getChatMessages(String sessionId) =>
      (select(chatMessages)
            ..where((m) => m.sessionId.equals(sessionId))
            ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
          .get();

  /// 全部会话的消息（备份导出用）。
  Future<List<ChatMessage>> getAllChatMessages() => select(chatMessages).get();

  /// 最近一个会话 id（冷启动续聊；无历史返回 null）。
  Future<String?> latestSessionId() async {
    final all = await (select(chatMessages)
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
          ..limit(1))
        .get();
    return all.isEmpty ? null : all.first.sessionId;
  }

  // ---- 学习者画像（memory_entries，M1）----

  /// 写一条画像（幂等去重由调用方（write_preference/策展器）保证）。
  Future<void> insertMemory(MemoryEntriesCompanion m) =>
      into(memoryEntries).insert(m);

  /// 某槽全部条目（时间正序）。
  Future<List<MemoryEntry>> getMemories(String slot) =>
      (select(memoryEntries)
            ..where((m) => m.slot.equals(slot))
            ..orderBy([(m) => OrderingTerm.asc(m.createdAt)]))
          .get();

  /// 全部画像（备份导出/清槽用）。
  Future<List<MemoryEntry>> getAllMemories() => select(memoryEntries).get();

  /// 清某槽（策展器重建用）。
  Future<void> clearSlot(String slot) =>
      (delete(memoryEntries)..where((m) => m.slot.equals(slot))).go();

  // ---- 文献 chunk（C1 逐句溯源）----

  /// 幂等插入 chunks（按 literatureId 先清后写——重建索引用）。
  Future<void> replaceLiteratureChunks(String literatureId, List<LiteratureChunksCompanion> chunks) async {
    await (delete(literatureChunks)..where((c) => c.literatureId.equals(literatureId))).go();
    await batch((b) => b.insertAll(literatureChunks, chunks));
  }

  /// 某文献全部 chunks（页序+段序）。
  Future<List<LiteratureChunk>> getChunks(String literatureId) =>
      (select(literatureChunks)
            ..where((c) => c.literatureId.equals(literatureId))
            ..orderBy([
              (c) => OrderingTerm.asc(c.pageNo),
              (c) => OrderingTerm.asc(c.paraIndex),
            ]))
          .get();

  /// 全部 chunks（索引重建用）。
  Future<List<LiteratureChunk>> getAllChunks() => select(literatureChunks).get();

  /// 按 id 取 chunk（引用校验/跳转用）。
  Future<LiteratureChunk?> getChunkById(String id) =>
      (select(literatureChunks)..where((c) => c.id.equals(id))).getSingleOrNull();

  /// preferences 判重（空白归一 casefold——DeepTutor write_preference 幂等同款）。
  Future<MemoryEntry?> findDuplicatePreference(String text) async {
    final key = text.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    final prefs = await getMemories('preferences');
    for (final p in prefs) {
      if (p.body.replaceAll(RegExp(r'\s+'), ' ').toLowerCase() == key) {
        return p;
      }
    }
    return null;
  }
}
// touch3
