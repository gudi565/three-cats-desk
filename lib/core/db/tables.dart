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
  TextColumn get noteId => text().nullable()();     // 同源组（Anki siblings：同 Note 生成的多张卡，如同段文字的多个挖空）
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
  IntColumn get year => integer().nullable()();        // 真题年份（如 2024；null=模拟/无年份）
  TextColumn get questionType => text().withDefault(const Constant('单选'))(); // 单选|多选|辨析|论述|简答|填空
  TextColumn get knowledgeTags => text().withDefault(const Constant('[]'))(); // 知识点标签 json 数组 ["马原-矛盾观"]
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

/// 笔记（知知模块，local-first）。title + content(Markdown 正文)。
/// 签名能力「笔记即卡片」：笔记块一键转念念复习卡（type=qa, source_app=zhizhi）。
class Notes extends Table {
  TextColumn get id => text()();                       // uuid
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get content => text().withDefault(const Constant(''))();   // Markdown 正文
  TextColumn get subject => text().withDefault(const Constant(''))();   // 学科标签（可选）
  TextColumn get sourceApp => text().withDefault(const Constant('zhizhi'))();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

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

/// 文献（渊渊模块，local-first）。真实检索（CrossRef）命中 + 手动录入。
/// 铁律：绝不 AI 造文献——所有文献来自真实公开 API / 手动录入；AI 只做基于已入库文献的问答（留口）。
/// 摘录/高亮 → 念念复习卡（type=highlight, source_app=yuanyuan，跨猫卡箱）。
class Literature extends Table {
  TextColumn get id => text()();                       // uuid
  TextColumn get title => text()();
  TextColumn get authors => text().withDefault(const Constant(''))();   // 作者（逗号分隔）
  TextColumn get year => text().withDefault(const Constant(''))();      // 年份
  TextColumn get venue => text().withDefault(const Constant(''))();     // 期刊/会议
  TextColumn get doi => text().withDefault(const Constant(''))();       // DOI（去重键）
  TextColumn get url => text().withDefault(const Constant(''))();       // 链接
  TextColumn get abstractText => text().withDefault(const Constant(''))(); // 摘要（CrossRef 可空）
  TextColumn get note => text().withDefault(const Constant(''))();      // 我的批注/摘录
  TextColumn get source => text().withDefault(const Constant('crossref'))(); // crossref / manual
  TextColumn get sourceApp => text().withDefault(const Constant('yuanyuan'))();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 本地留存度量（本地部署方向，2026-08-13）。无云端后「用户用没用」会失明——
/// v1 正是死于零验证。这张表是本地专属版的「观测仪器」：
/// 每天打开记一行（upsert by day），记录当天打开了几次、复习了几张、专注了几分钟、
/// 猫 intimacy 快照。既是用户自己的坚持仪表盘（专属功能卖点），也是诊断包导出的数据源
/// （客户自愿回传换月更内容 → 我们的留存信号回来了，不依赖云）。
class ActivityLog extends Table {
  TextColumn get day => text()();                       // YYYY-MM-DD（主键，当天 0 点对齐）
  IntColumn get openCount => integer().withDefault(const Constant(0))(); // 当日打开次数
  IntColumn get reviewed => integer().withDefault(const Constant(0))();  // 当日复习张数
  IntColumn get focusMinutes => integer().withDefault(const Constant(0))(); // 当日专注分钟
  IntColumn get intimacy => integer().withDefault(const Constant(0))();  // 当日猫亲密度快照
  DateTimeColumn get firstOpenedAt => dateTime().nullable()(); // 当日首次打开
  DateTimeColumn get lastOpenedAt => dateTime().nullable()();  // 当日最近打开

  @override
  Set<Column> get primaryKey => {day};
}

/// 智能体对话记录（P2-1，2026-08-15）。local-first：一切在 drift，
/// 进 BackupService——用户和智能体的聊天历史是他的资产，换机必须可迁移。
/// role: user / assistant / tool（工具调用事件转存）；events 存该轮 AgentEvent JSON。
class ChatMessages extends Table {
  TextColumn get id => text()();                       // uuid
  TextColumn get sessionId => text()();                // 会话 id（同会话按时间排序）
  TextColumn get role => text()();                     // user / assistant / tool
  TextColumn get content => text()();                  // 文本内容（user 问题/assistant 回答/工具结果）
  TextColumn get eventsJson => text().withDefault(const Constant(''))(); // 该轮 typed 事件存档（调试/回放）
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 文献 chunk（C1，2026-08-17）——逐句溯源的锚点层。
/// 切段时就带坐标（页/段/字符偏移），检索命中后可精确定位回原文——
/// "防 AI 瞎编"的业界标准做法：锚点入库，而非事后找。
class LiteratureChunks extends Table {
  TextColumn get id => text()();                       // uuid
  TextColumn get literatureId => text()();             // 所属文献
  IntColumn get pageNo => integer().withDefault(const Constant(0))();    // 页码（1 起，0=未知）
  IntColumn get paraIndex => integer().withDefault(const Constant(0))(); // 段落序（0 起）
  IntColumn get offsetStart => integer().withDefault(const Constant(-1))(); // 字符偏移（-1=未记）
  IntColumn get offsetEnd => integer().withDefault(const Constant(-1))();
  TextColumn get body => text()();                     // chunk 文本
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// 学习者画像（M1，2026-08-16）。DeepTutor L3 四槽思想的本地版：
///   recent      — 近期活动滚动时间线（策展器写）
///   profile     — 身份/学习风格（策展器写，多源证据才收）
///   scope       — 知识点掌握度三态（策展器写，**基于行为事件而非年级代理**——Bokosmaty 验证结论）
///   preferences — 显式偏好（智能体 write_preference 写，用户原话优先）
/// 条目规范：text ≤ 240、带对冲措辞（"在 N 次做题中…"）、refs 记数据来源。
class MemoryEntries extends Table {
  TextColumn get id => text()();                       // m_ + uuid
  TextColumn get slot => text()();                     // recent/profile/scope/preferences
  TextColumn get body => text()();                     // ≤240 字，对冲措辞（列名避开 drift 的 text builder）
  TextColumn get refs => text().withDefault(const Constant(''))(); // 数据来源（如 wenwen:attempts）
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}
