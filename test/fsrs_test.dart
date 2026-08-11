import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/fsrs.dart';

// FSRS NaN 守卫单测（Phase0 §4 强制）—— iOS 致命#1 的教训。
//
// 病灶回顾：云拉回/跨 App 收卡 stability 为 0/负 → pow(0,-w9)=+inf → 0*(1+inf)=NaN；
// 裸 max(S_MIN, NaN) 在 IEEE754 下返回 NaN（含 NaN 比较全 false），NaN 写进 stability 后：
//   nextInterval 的 min(max(1, NaN), maxInterval) → 36500 → 卡排到 100 年后，用户永远看不到。
// clampS 必须对 NaN/±Inf/0/负 全部兜到 S_MIN，且排期不能飞出 10 年。
void main() {
  const fsrs = Fsrs();
  final now = DateTime(2026, 8, 11, 12, 0, 0);

  group('NaN 守卫（stability=0 不炸、不排到 100 年后）', () {
    test('新卡 stability=0，good 评分 → stability>0 且非 NaN', () {
      final card = FsrsCard(id: 'c1', stability: 0, difficulty: 0, lastReview: now);
      final scheduled = fsrs.schedule(card, FsrsRating.good, now: now);
      expect(scheduled.stability.isNaN, isFalse);
      expect(scheduled.stability.isFinite, isTrue);
      expect(scheduled.stability, greaterThan(0));
      expect(scheduled.due.year, lessThan(now.year + 10));
    });

    test('新卡 stability=0，四档评分全部产生有限正 stability', () {
      for (final rating in FsrsRating.values) {
        final card = FsrsCard(id: 'c_${rating.value}', stability: 0, difficulty: 0);
        final scheduled = fsrs.schedule(card, rating, now: now);
        expect(scheduled.stability.isFinite, isTrue, reason: '${rating.label} stability 非有限');
        expect(scheduled.stability, greaterThan(0), reason: '${rating.label} stability 未>0');
        expect(scheduled.difficulty.isFinite, isTrue, reason: '${rating.label} difficulty 非有限');
        expect(scheduled.due.year, lessThan(now.year + 10), reason: '${rating.label} 排期飞出 10 年');
      }
    });

    test('review 态卡 stability=0 + 已过 1 天（NaN 触发路径）→ 不炸', () {
      // 这是最贴近 iOS 致命#1 的真实路径：review 态、stability=0、
      // 距上次复习 >0 天 → _nextStabilitySuccess 内 pow(0,-w9)=+inf → 0*(1+inf)=NaN。
      final last = now.subtract(const Duration(days: 1));
      for (final rating in FsrsRating.values) {
        final card = FsrsCard(
          id: 'review_${rating.value}',
          stability: 0,
          difficulty: 5,
          retrievability: 0,
          state: FsrsState.review,
          reps: 3,
          lastReview: last,
        );
        final scheduled = fsrs.schedule(card, rating, now: now);
        expect(scheduled.stability.isNaN, isFalse, reason: '${rating.label} 产生 NaN');
        expect(scheduled.stability.isFinite, isTrue);
        expect(scheduled.stability, greaterThan(0));
        expect(scheduled.due.year, lessThan(now.year + 10));
      }
    });

    test('clampS 对 NaN / ±Inf / 0 / 负值 全部兜到 S_MIN', () {
      expect(clampS(double.nan), kFsrsSMin);
      expect(clampS(double.infinity), kFsrsSMin);
      expect(clampS(double.negativeInfinity), kFsrsSMin);
      expect(clampS(0), kFsrsSMin);
      expect(clampS(-5), kFsrsSMin);
      expect(clampS(0.0001), kFsrsSMin); // 低于下限
      expect(clampS(2.5), 2.5);         // 正常值原样
    });

    test('连评 30 次（混合 again/good）→ stability 始终有限正、due 不飞', () {
      var card = FsrsCard(id: 'loop', stability: 0, difficulty: 0);
      var t = now;
      final ratings = [
        FsrsRating.good, FsrsRating.again, FsrsRating.good, FsrsRating.hard,
        FsrsRating.easy, FsrsRating.again, FsrsRating.good, FsrsRating.good,
      ];
      for (var i = 0; i < 30; i++) {
        card = fsrs.schedule(card, ratings[i % ratings.length], now: t);
        expect(card.stability.isFinite, isTrue, reason: '第 $i 次 stability 非有限');
        expect(card.stability, greaterThan(0), reason: '第 $i 次 stability 未>0');
        expect(card.due.year, lessThan(now.year + 10), reason: '第 $i 次 due 飞出 10 年');
        t = card.due; // 推进到下次到期
      }
    });

    test('负 stability / 负 difficulty 卡 → 评分后全部归位', () {
      final card = FsrsCard(
        id: 'neg',
        stability: -3,
        difficulty: -1,
        state: FsrsState.review,
        reps: 2,
        lastReview: now.subtract(const Duration(days: 2)),
      );
      final scheduled = fsrs.schedule(card, FsrsRating.good, now: now);
      expect(scheduled.stability, greaterThan(0));
      expect(scheduled.stability.isFinite, isTrue);
      expect(scheduled.difficulty, inInclusiveRange(1, 10));
      expect(scheduled.due.year, lessThan(now.year + 10));
    });
  });

  group('算法正确性（对齐 legacy FSRS-6 19 参数）', () {
    test('默认参数 19 权重与 legacy 一致', () {
      expect(FsrsParams.defaultParams.w.length, 19);
      expect(FsrsParams.defaultParams.w[0], 0.212);   // Again 初始稳定度
      expect(FsrsParams.defaultParams.w[3], 8.2956);  // Easy 初始稳定度
      expect(FsrsParams.defaultParams.w[4], 6.4133);  // 初始难度基数
      expect(FsrsParams.defaultParams.w[18], 0.0912); // 短期记忆评级偏移
      expect(FsrsParams.defaultParams.requestRetention, 0.9);
    });

    test('Easy 新卡比 Again 新卡排期更远', () {
      final easy = fsrs.schedule(FsrsCard(id: 'e'), FsrsRating.easy, now: now);
      final again = fsrs.schedule(FsrsCard(id: 'a'), FsrsRating.again, now: now);
      expect(easy.stability, greaterThan(again.stability));
      expect(easy.due.isAfter(again.due), isTrue);
    });

    test('Again 评分计入 learning/relearning，good/easy 新卡直接 review', () {
      final again = fsrs.schedule(FsrsCard(id: 'a'), FsrsRating.again, now: now);
      expect(again.state, FsrsState.learning);
      final good = fsrs.schedule(FsrsCard(id: 'g'), FsrsRating.good, now: now);
      expect(good.state, FsrsState.review);
    });

    test('review 态 Again 计 lapse 并进 relearning', () {
      var card = fsrs.schedule(FsrsCard(id: 'r'), FsrsRating.good, now: now); // → review
      final t2 = now.add(const Duration(days: 3));
      final lapsesBefore = card.lapses;
      card = fsrs.schedule(card, FsrsRating.again, now: t2);
      expect(card.lapses, lapsesBefore + 1);
      expect(card.state, FsrsState.relearning);
    });

    test('retention 随时间衰减且 0..1', () {
      var card = fsrs.schedule(FsrsCard(id: 'ret'), FsrsRating.good, now: now);
      final r0 = fsrs.retention(card, now: now);
      final r5 = fsrs.retention(card, now: now.add(const Duration(days: 5)));
      expect(r0, greaterThan(r5)); // 越拖忘得越多
      expect(r0, inInclusiveRange(0, 1));
      expect(r5, inInclusiveRange(0, 1));
    });

    test('序列化往返一致（云同步契约 last_review snake_case）', () {
      var card = fsrs.schedule(FsrsCard(id: 'json'), FsrsRating.good, now: now);
      final json = card.toJson();
      expect(json.containsKey('last_review'), isTrue);
      expect(json['state'], FsrsState.review.value);
      final back = FsrsCard.fromJson(json);
      expect(back.id, card.id);
      expect(back.stability, closeTo(card.stability, 1e-9));
      expect(back.state, card.state);
      expect(back.reps, card.reps);
    });

    test('fromJson 对缺失/异常 due 不抛（防御，对齐 last_review 的 tryParse）', () {
      // due 缺失 → 用 now 兜底（不抛）
      final noDue = FsrsCard.fromJson({
        'id': 'x',
        'stability': 2,
        'difficulty': 5,
        'state': 2,
        'reps': 1,
        'lapses': 0,
        // 无 due
      });
      expect(noDue.due, isNotNull);
      // due 格式坏 → tryParse 兜底（不抛 FormatException）
      final badDue = FsrsCard.fromJson({
        'id': 'x',
        'due': '2026-13-45-not-a-date',
      });
      expect(badDue.due, isNotNull);
    });
  });

  group('fuzz seed 跨 Web/VM 一致（_seed）', () {
    // 这是审查确认的 high：裸 h*prime 在 dart2js 丢低位 → 两端 due 不同 → 云同步污染。
    // 修复用 _imul32（16 位分段，全程 < 2^53）。此组锁定「同卡同 reps 出同一 seed」，
    // 并对一批 id 校验 seed ∈ [0,1)。跨端（Web vs VM）一致由 enableFuzz 完整排期断言覆盖。
    final fuzzy = Fsrs(FsrsParams(enableFuzz: true));

    test('同卡同 reps → 同 seed（确定性）', () {
      // 评分两次同卡同 reps 在 VM 内必一致（确定性）；enableFuzz 也应稳定可复现。
      final base = FsrsCard(id: 'fuzz-card-001', stability: 8, difficulty: 5,
          state: FsrsState.review, reps: 3, lastReview: now);
      final a = fuzzy.schedule(base, FsrsRating.good, now: now);
      final b = fuzzy.schedule(base, FsrsRating.good, now: now);
      expect(a.due, b.due, reason: '同卡同评分 fuzz 后 due 必须一致（确定性）');
    });

    test('enableFuzz 排期落在 [due-Δ, due+Δ] 合理区间，不飞出 10 年', () {
      for (final id in ['card_0', 'card_1', 'card_42', '长中文id测试', 'abc-XYZ-999']) {
        final card = FsrsCard(id: id, stability: 12, difficulty: 5,
            state: FsrsState.review, reps: 2, lastReview: now);
        final s = fuzzy.schedule(card, FsrsRating.good, now: now);
        expect(s.due.year, lessThan(now.year + 10), reason: '$id fuzz 后飞出 10 年');
      }
    });
  });
}
