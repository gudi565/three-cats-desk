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

/// 题库（稳稳模块，local-first）。内置考研题 + 导入。
/// 单选（options json 数组 + answerIndex）。题干/解析 Markdown。
class Questions extends Table {
  TextColumn get id => text()();                       // 题 id（内容侧给定，如 zz-001）
  TextColumn get stem => text()();                     // 题干
  TextColumn get optionsJson => text()();              // 选项 json 数组 ["A...","B...","C...","D..."]
  IntColumn get answerIndex => integer()();            // 正确选项下标 0-3
  TextColumn get explanation => text().nullable()();   // 解析
  TextColumn get subject => text().withDefault(const Constant('政治'))(); // 科目
  TextColumn get source => text().withDefault(const Constant(''))();      // 来源标签
  TextColumn get sourceApp => text().withDefault(const Constant('wenwen'))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 做题记录（稳稳）。一次作答 = 一行。
/// isCorrect 客观判分（0 LLM）；correct 写 cloud attempts 表；错（isCorrect=false）→ 生成念念复习卡。
class Attempts extends Table {
  TextColumn get id => text()();                       // uuid
  TextColumn get questionId => text()();               // 所属题
  IntColumn get selectedIndex => integer()();          // 用户选的选项下标
  BoolColumn get isCorrect => boolean()();             // 客观判分
  DateTimeColumn get answeredAt => dateTime().withDefault(currentDateAndTime)();
  TextColumn get sourceApp => text().withDefault(const Constant('wenwen'))();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 专注记录（暖暖模块，local-first 主存储）。一次专注 = 一行。
///
/// 暖暖只写 focus_sessions（source_app=nuannuan），不写 cards——它是"让你坐得住"，
/// 不是"让你记住"。完成/放弃都留痕（放弃软化：completed=false，不惩罚，猫"等你回来"）。
/// actualSeconds 是真实专注时长；completed=true 且 actualSeconds 满 plannedMinutes 才算"完成"。
class FocusSessions extends Table {
  TextColumn get id => text()();                       // uuid
  DateTimeColumn get startedAt => dateTime()();        // 开始时刻（今日总览按天过滤用）
  IntColumn get plannedMinutes => integer()();         // 计划专注分钟
  IntColumn get actualSeconds => integer().withDefault(const Constant(0))(); // 实际专注秒
  BoolColumn get completed => boolean().withDefault(const Constant(false))(); // 是否完成（false=放弃留痕）
  TextColumn get sourceApp => text().withDefault(const Constant('nuannuan'))();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();    // 是否已上云
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
