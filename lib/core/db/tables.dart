import 'package:drift/drift.dart';

/// 本地词书（牌组）镜像。对应 Supabase decks 表的本地缓存。
///
/// Phase0：词书主要来自 assets 导入（builtIn=true），id 由词书 contentHash 决定，
/// 复导判重。云同步 decks 是 Phase 后续（清单 §6 只要求 cards 上云）。
class LocalDecks extends Table {
  TextColumn get id => text()();                    // uuid
  TextColumn get name => text()();
  TextColumn get kind => text().withDefault(const Constant('vocab'))(); // vocab|glossary
  IntColumn get accentHex => integer().withDefault(const Constant(4099754))();
  BoolColumn get builtIn => boolean().withDefault(const Constant(true))();
  TextColumn get contentHash => text().withDefault(const Constant(''))(); // 复导判重
  IntColumn get cardCount => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本地卡镜像（local-first 主存储）。评分后先落这里，再异步上云。
///
/// fsrsState 存整个 FSRS jsonb 字符串（对齐 Supabase cards.fsrs_state），
/// 里面含 stability/difficulty/state/reps/lapses/last_review/due。
/// due/state 单列出来做查询索引（今日到期卡）。
class LocalCards extends Table {
  TextColumn get id => text()();                    // uuid
  TextColumn get deckId => text().nullable()();     // 所属词书（软引用 LocalDecks.id）
  TextColumn get type => text().withDefault(const Constant('qa'))(); // qa|cloze|error|highlight|note
  TextColumn get front => text()();
  TextColumn get back => text().nullable()();
  TextColumn get sourceApp => text().withDefault(const Constant('niannian'))();
  TextColumn get fsrsState => text()();             // FSRS jsonb 字符串
  DateTimeColumn get due => dateTime().withDefault(currentDateAndTime)(); // 查询索引（来自 fsrsState.due）
  IntColumn get state => integer().withDefault(const Constant(0))();      // 查询索引（0 new/1 learning/2 review/3 relearning）
  BoolColumn get synced => boolean().withDefault(const Constant(false))(); // 是否已上云（同步标记）
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
