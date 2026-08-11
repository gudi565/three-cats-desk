import 'dart:math';

// MARK: - FSRS-6 · 自由间隔重复算法引擎（从 legacy Swift CatSRS/FSRS.swift 手译）
//
// 来源（只读参考，勿改）：
//   /Users/serein/Desktop/《三猫书桌》/01_代码工程/深海2/三猫书桌/ThreeCatsKit/Sources/CatSRS/FSRS.swift
//
// 为什么是手译而非 pub.dev `fsrs` 包（Phase0 §4 裁决，2026-08-11）：
//   pub.dev fsrs@2.0.1 是 21 参数 FSRS-6 变体，defaultParameters 与 legacy 19 权重完全不同，
//   且内部带 learningSteps(1m/10m)/relearningSteps(10m) 分钟级步进、_decay=-w[20]、
//   w[19] 短期幂（s^-w19 项）等 legacy 明确烘焙为常量的行为。为与现有 Supabase 云数据
//   （fsrs_state jsonb，念念/稳稳等跨 App 共享）逐字段对齐，直接手译 legacy 19 参数版本，
//   保证同卡在两平台算出同样的 stability/due。
//
// 与 legacy 的刻意差异（仅实现细节，算法语义 1:1）：
//   • id 用 String（uuid）而非 Swift UUID —— drift TEXT 列存储，跨端无类型。
//   • due/lastReview 用 DateTime；addDays 的 <1 天走秒、≥1 天按整天，对齐 legacy。
//   • seed() 用 FNV-1a 64 哈希（与 Swift 同算法），fuzz 可复现。
//   • 不实现 SRSGrade 互转 / migrate(from SM-2) —— Flutter 端无 SM-2 旧数据要迁。

/// 评分（与 FSRS 标准对齐：Again=1 Hard=2 Good=3 Easy=4）
enum FsrsRating {
  again(1, '不认识'),
  hard(2, '模糊'),
  good(3, '认识'),
  easy(4, '简单');

  final int value;
  final String label;
  const FsrsRating(this.value, this.label);

  static FsrsRating fromValue(int v) =>
      FsrsRating.values.firstWhere((r) => r.value == v, orElse: () => FsrsRating.good);
}

/// 卡状态（对齐 legacy FSRSState：new=0 learning=1 review=2 relearning=3）
enum FsrsState {
  newCard(0),
  learning(1),
  review(2),
  relearning(3);

  final int value;
  const FsrsState(this.value);

  static FsrsState fromValue(int v) =>
      FsrsState.values.firstWhere((s) => s.value == v, orElse: () => FsrsState.newCard);
}

/// 参数（19 权重，FSRS-6 默认值；与 legacy FSRSParams.w 逐项一致）
class FsrsParams {
  /// FSRS-6 默认 19 权重。下标语义见 legacy 注释：
  ///   0..3 初始稳定度；4 初始难度基数；5 初始难度斜率；6 后续难度斜率；7 难度均值回归权重；
  ///   8..10 答对稳定度；11..14 答错稳定度；15 Hard 惩罚；16 Easy 加成；17/18 短期记忆。
  final List<double> w;
  final double requestRetention; // 目标保留率（默认 90%）
  final double maxInterval;      // 最大间隔（天）
  final bool enableFuzz;         // 是否启用 fuzz（默认关，便于测试）
  final bool enableShortTerm;    // FSRS-6 短期记忆模型开关

  const FsrsParams({
    this.w = const [
      // w[0..3]  初始稳定度（Again/Hard/Good/Easy）
      0.212, 1.2931, 2.3065, 8.2956,
      // w[4..7]  难度（基数 / 初始斜率 / 后续斜率 / 均值回归权重）
      6.4133, 0.8334, 3.0194, 0.001,
      // w[8..10] 答对后稳定度（exp 系数 / S 负幂 / (1-R) 系数）
      1.8722, 0.1666, 0.796,
      // w[11..14] 答错后稳定度（乘子 / D 负幂 / S+1 幂 / (1-R) 系数）
      1.4835, 0.0614, 0.2629, 1.6483,
      // w[15..16] Hard 惩罚 / Easy 加成
      0.6014, 1.8729,
      // w[17..18] 短期记忆（指数增益 / 评级偏移）
      0.5425, 0.0912,
    ],
    this.requestRetention = 0.9,
    this.maxInterval = 36500,
    this.enableFuzz = false,
    this.enableShortTerm = true,
  });

  static const FsrsParams defaultParams = FsrsParams();
}

/// 稳定度下限（v6 S_MIN）。
const double kFsrsSMin = 0.001;

/// 稳定度下界夹逼 + NaN 兜底（iOS 致命#1 教训，2026-08-11）。
///
/// 病灶：裸 max(S_MIN, x) 在 x 为 NaN 时（IEEE754 下含 NaN 的比较全为 false）
/// 会返回 NaN 而非下界。NaN 一旦写入 stability：
///   nextIntervalDays 的 min(max(1, NaN), maxInterval) → 36500 → 把卡排到 100 年后；
///   且 NaN 会编码进 jsonb 污染云同步。
/// 触发路径现实存在：云拉回/跨 App 收卡 stability 为 0/负 → pow(0,-w9)=+inf → 0*(1+inf)=NaN。
/// 所有写入 stability 的出口统一走本函数兜底。
double clampS(double x) => (x.isFinite && x > kFsrsSMin) ? x : kFsrsSMin;

/// FSRS 卡片（字段对齐 supabase cards.fsrs_state jsonb 与 legacy FSRSCard）。
class FsrsCard {
  String id;
  double stability;      // 记忆稳定性（天）
  double difficulty;     // 难度 1..10
  double retrievability; // 当前可提取度 0..1（上次复习时刻快照）
  FsrsState state;
  int reps;
  int lapses;
  DateTime? lastReview;
  DateTime due;

  FsrsCard({
    required this.id,
    this.stability = 0,
    this.difficulty = 0,
    this.retrievability = 0,
    this.state = FsrsState.newCard,
    this.reps = 0,
    this.lapses = 0,
    this.lastReview,
    DateTime? due,
  }) : due = due ?? DateTime.now();

  FsrsCard copy() => FsrsCard(
        id: id,
        stability: stability,
        difficulty: difficulty,
        retrievability: retrievability,
        state: state,
        reps: reps,
        lapses: lapses,
        lastReview: lastReview,
        due: due,
      );

  /// 序列化为云同步 jsonb（snake_case，对齐 schema §1.5 FSRSState 契约）。
  /// lastReview → last_review（legacy CodingKeys 显式映射同源）。
  Map<String, dynamic> toJson() => {
        'id': id,
        'stability': stability,
        'difficulty': difficulty,
        'retrievability': retrievability,
        'state': state.value,
        'reps': reps,
        'lapses': lapses,
        'last_review': lastReview?.toIso8601String(),
        'due': due.toIso8601String(),
      };

  static FsrsCard fromJson(Map<String, dynamic> j) => FsrsCard(
        id: j['id'] as String,
        stability: (j['stability'] as num?)?.toDouble() ?? 0,
        difficulty: (j['difficulty'] as num?)?.toDouble() ?? 0,
        retrievability: (j['retrievability'] as num?)?.toDouble() ?? 0,
        state: FsrsState.fromValue((j['state'] as num?)?.toInt() ?? 0),
        reps: (j['reps'] as num?)?.toInt() ?? 0,
        lapses: (j['lapses'] as num?)?.toInt() ?? 0,
        lastReview: j['last_review'] != null ? DateTime.tryParse(j['last_review'] as String) : null,
        // tryParse 对齐 last_review 的防御：异常/缺字段不抛（云拉回坏行不应中断整个 pull）。
        due: (j['due'] == null)
            ? DateTime.now()
            : (DateTime.tryParse(j['due'] as String) ?? DateTime.now()),
      );

  /// 按天对齐：due 的「那一天」开始就算到期。
  bool get isDue {
    final now = DateTime.now();
    final d = DateTime(due.year, due.month, due.day);
    final n = DateTime(now.year, now.month, now.day);
    return !d.isAfter(n);
  }
}

/// FSRS 引擎（纯函数，不持有状态）。
class Fsrs {
  final FsrsParams params;
  const Fsrs([this.params = FsrsParams.defaultParams]);

  /// 评分一次，返回更新后的卡片。
  FsrsCard schedule(FsrsCard card, FsrsRating rating, {DateTime? now}) {
    now ??= DateTime.now();
    var c = card.copy();
    final g = rating.value.toDouble(); // 1..4
    final elapsed = _elapsedDays(c.lastReview, now);
    final r = _retrievability(elapsed, c.stability); // new/stability=0 → R=0
    final st = params.enableShortTerm;

    switch (c.state) {
      case FsrsState.newCard:
        c.difficulty = _clamp(_initDifficulty(g), 1, 10);
        c.stability = clampS(_initStability(g));
        c.state = (rating == FsrsRating.good || rating == FsrsRating.easy)
            ? FsrsState.review
            : FsrsState.learning;
        c.reps = max(c.reps, 1);

      case FsrsState.learning:
      case FsrsState.relearning:
        c.difficulty = _clamp(_nextDifficulty(c.difficulty, g), 1, 10);
        if (st && elapsed < 1.0) {
          c.stability = clampS(_nextShortTermStability(c.stability, g));
        } else if (rating == FsrsRating.again) {
          c.stability = clampS(_nextStabilityFail(c.difficulty, c.stability, r));
        } else {
          c.stability = clampS(_nextStabilitySuccess(c.difficulty, c.stability, r, rating));
        }
        if (rating == FsrsRating.again) {
          c.state = (c.state == FsrsState.relearning) ? FsrsState.relearning : FsrsState.learning;
        } else {
          c.state = FsrsState.review; // good/easy 毕业；hard 无 learning_steps 也毕业
        }
        c.reps += 1;

      case FsrsState.review:
        c.difficulty = _clamp(_nextDifficulty(c.difficulty, g), 1, 10);
        if (st && elapsed < 1.0) {
          c.stability = clampS(_nextShortTermStability(c.stability, g));
        } else if (rating == FsrsRating.again) {
          c.lapses += 1;
          c.stability = clampS(_nextStabilityFail(c.difficulty, c.stability, r));
          c.state = FsrsState.relearning;
        } else {
          c.stability = clampS(_nextStabilitySuccess(c.difficulty, c.stability, r, rating));
          c.state = FsrsState.review;
        }
        c.reps += 1;
    }

    // 排期（v6 分段 fuzz，elapsedDays 用于保证 fuzz 后间隔 > 已过天数）
    final interval = _nextIntervalDays(
      c.stability,
      fuzzSeed: params.enableFuzz ? _seed(c.id, c.reps) : null,
      elapsedDays: elapsed,
    );
    c.lastReview = now;
    c.due = _addDays(interval, now);
    c.retrievability = _retrievability(0, c.stability); // 刚复习完≈高
    return c;
  }

  /// 当前保留率（UI 遗忘曲线用）：R(t) = (1 + t/(9·S))^-1。
  double retention(FsrsCard card, {DateTime? now}) {
    now ??= DateTime.now();
    final elapsed = _elapsedDays(card.lastReview, now);
    return _retrievability(elapsed, card.stability);
  }

  // MARK: - 核心公式（FSRS-6）

  /// 初始稳定度：Again/Hard/Good/Easy → w[0..3]。
  double _initStability(double g) => clampS(params.w[g.toInt() - 1]);

  /// 初始难度（v6 exp 形）：D0(G) = w[4] - exp((G-1)·w[5]) + 1。
  double _initDifficulty(double g) => params.w[4] - exp((g - 1) * params.w[5]) + 1;

  /// linear damping：ΔD 在高难度区压缩，防 D 漂到 10 钉死。
  double _linearDamping(double deltaD, double oldD) => deltaD * (10 - oldD) / 9;

  /// 下一难度（v6）：ΔD = -w[6]·(g-3)，加 damping，最后均值回归到 D0(Easy=4)。
  double _nextDifficulty(double d, double g) {
    final deltaD = -params.w[6] * (g - 3);
    final nextD = d + _linearDamping(deltaD, d);
    return params.w[7] * _initDifficulty(4.0) + (1 - params.w[7]) * nextD;
  }

  /// 答对后稳定度：S' = S·(1 + e^w8·(11-D)·S^-w9·(e^((1-R)·w10)-1))·hardPen·easyBonus。
  double _nextStabilitySuccess(double d, double s, double r, FsrsRating rating) {
    final hardPenalty = rating == FsrsRating.hard ? params.w[15] : 1.0;
    final easyBonus = rating == FsrsRating.easy ? params.w[16] : 1.0;
    final factor = exp(params.w[8]) *
        (11 - d) *
        pow(s, -params.w[9]) *
        (exp((1 - r) * params.w[10]) - 1);
    return s * (1 + factor) * hardPenalty * easyBonus;
  }

  /// 答错（遗忘）后稳定度（v6）：S' = w11·D^-w12·((S+1)^w13-1)·e^((1-R)·w14)；
  /// 启用短期记忆时加 leps 上限 S' ≤ S / e^{w17·w18}。
  double _nextStabilityFail(double d, double s, double r) {
    final sFail = params.w[11] *
        pow(d, -params.w[12]) *
        (pow(s + 1, params.w[13]) - 1) *
        exp((1 - r) * params.w[14]);
    if (params.enableShortTerm) {
      final lepsCap = s / exp(params.w[17] * params.w[18]);
      return min(sFail, lepsCap);
    }
    return sFail;
  }

  /// 短期记忆稳定度（v6 slide）：S' = S · sinc，sinc = exp(w17·(g-3+w18))。
  /// Hard/Good/Easy 强制 sinc ≥ 1；Again 允许 sinc < 1。19-param 烘焙 w[19]=0 → s^0=1。
  double _nextShortTermStability(double s, double g) {
    final sinc = exp(params.w[17] * (g - 3 + params.w[18]));
    final masked = g >= 2.0 ? max(sinc, 1.0) : sinc;
    return s * masked;
  }

  /// 可提取度 R(t) = (1+t/(9S))^-1。
  double _retrievability(double elapsed, double stability) {
    if (stability <= 0) return 0;
    return pow(1 + elapsed / (9 * stability), -1).toDouble();
  }

  /// 下次复习间隔（天）：intervalModifier = 9·(1/ret - 1)，v6 分段 fuzz 在 interval≥2.5 时启用。
  double _nextIntervalDays(double stability, {double? fuzzSeed, double elapsedDays = 0}) {
    final intervalModifier = 9.0 * (1.0 / params.requestRetention - 1.0);
    var interval = stability * intervalModifier;
    interval = min(max(1, interval), params.maxInterval);
    if (fuzzSeed != null && interval >= 2.5) {
      final range = _fuzzRange(interval, elapsedDays);
      interval = min(range.lo + (fuzzSeed * (range.hi - range.lo + 1)).floor(), range.hi).toDouble();
    }
    return max(1, interval);
  }

  /// v6 分段 fuzz 桶。返回 [lo, hi]，保证 lo > elapsedDays 且 ≤ hi。
  ({int lo, int hi}) _fuzzRange(double interval, double elapsedDays) {
    var delta = 1.0;
    delta += 0.15 * max(min(interval, 7.0) - 2.5, 0);
    delta += 0.10 * max(min(interval, 20.0) - 7.0, 0);
    delta += 0.05 * max(interval - 20.0, 0);
    final cappedIvl = min(interval, params.maxInterval);
    var lo = max(2, (cappedIvl - delta).round());
    final hi = min((cappedIvl + delta).round(), params.maxInterval.toInt());
    if (cappedIvl > elapsedDays) {
      lo = max(lo, elapsedDays.toInt() + 1);
    }
    lo = min(lo, hi);
    return (lo: lo, hi: hi);
  }

  // MARK: - 时间工具

  double _elapsedDays(DateTime? last, DateTime now) {
    if (last == null) return 0;
    return max(0, now.difference(last).inMilliseconds / 86400000.0);
  }

  DateTime _addDays(double days, DateTime now) {
    if (days < 1) {
      return now.add(Duration(milliseconds: (days * 86400000).round())); // <1 天按秒
    }
    return DateTime(now.year, now.month, now.day + days.round(), now.hour, now.minute, now.second);
  }

  double _clamp(double x, double lo, double hi) => min(max(x, lo), hi);

  /// 确定性伪随机 [0,1)：FNV-1a，由 卡片id + reps 派生，fuzz 可复现。
  ///
  /// 实现：32 位 FNV-1a。**跨 Web/安卓一致**是硬契约（同卡同 reps 在两端算出同一 seed，
  /// 否则 fuzz 会给两端不同的 due，污染 Supabase fsrs_state 云同步）。
  ///
  /// 关键：乘法用 16 位分段（hi/lo），避免 h * prime 的中间值超过 2^53。
  /// dart2js 的 number 是 JS double，安全整数仅 53 位；裸 h * 0x01000193（最大 ~7.2e16）
  /// 会丢低位 → &0xFFFFFFFF 后两端结果不同。分段后每个乘积 < 2^49，全程精确。
  /// 与 64 位 VM 逐位一致（已加跨端单测 fsrs_test.dart「_seed 跨 Web/VM 一致」）。
  double _seed(String cardId, int reps) {
    var h = 0x811C9DC5; // FNV-1a 32 offset basis
    for (final b in cardId.codeUnits) {
      h ^= b;
      h = _imul32(h, 0x01000193); // FNV-1a 32 prime
    }
    h ^= reps;
    h = _imul32(h, 0x01000193);
    return (h & 0x7FFFFFFF) / 0x80000000; // → [0,1)，半开（除 2^31 避免 1.0）
  }

  /// 32 位整数乘法，跨 dart2js（Web）与 VM 一致，结果 = (a*b) mod 2^32。
  /// 把 a/b 拆成 hi/lo 各 16 位相乘，避免任一中间乘积超过 2^53（JS double 安全整数上限）：
  ///   a*b = ah*bh*2^32 + (ah*bl + al*bh)*2^16 + al*bl
  /// ah*bh*2^32 ≡ 0 (mod 2^32)，所以 mod 2^32 = (ah*bl + al*bh)*2^16 + al*bl，
  /// 再带上 al*bl 的高 16 位进位。各分项均 < 2^32，<<16 后 < 2^48（< 2^53 安全）。
  int _imul32(int a, int b) {
    const mask = 0xFFFF;
    final ah = (a >> 16) & mask;
    final al = a & mask;
    final bh = (b >> 16) & mask;
    final bl = b & mask;
    final cross = al * bh + ah * bl; // < 2^17
    final ll = al * bl; // < 2^32
    final lo16 = ll & mask;
    final mid = (ll >> 16) + cross; // < 2^17 + 2^16 < 2^18
    return ((mid << 16) | lo16) & 0xFFFFFFFF;
  }
}
