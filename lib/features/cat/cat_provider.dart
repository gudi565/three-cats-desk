import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 猫养成数据层（Phase 1a）。
///
/// 验证的核心 hook：「用户会不会为了猫第二天再打开」。
/// intimacy = 历史累计复习次数（只增，永不衰减/不扣）。
/// 为什么只增不扣：考研人群本就焦虑，衰减会攻击情绪；次日留存看的是「打开」行为本身，
/// 卡片仍按 FSRS 正常排期，猫只负责提供正反馈与归属感。关掉几天回来，数字还在 → 有亲切感。
///
/// 持久化用 SharedPreferences（已有依赖），1a 不做跨设备同步——验证 hook 不需要云同步猫进度。
/// 进度归因（决策 2026-08-12）：复习一张卡 → +1，不区分评分档位（again 也 +1）。
///
/// 修复（审计 P1）：cat key 按 userId 命名空间隔离——SharedPreferences 是按 App 共享的，同一台
/// 设备上账号 A 退出、账号 B 登录，会读到 A 的 intimacy（跨账号串数据）。提供 bindUser(userId)
/// 在登录态确立时重绑定命名空间并重载；未登录用 '_anon' 命名空间。
class CatNotifier extends StateNotifier<CatState> {
  static const _keyIntimacy = 'cat.intimacy';
  static const _keyTodayReviewed = 'cat.today_reviewed';
  static const _keyTodayDate = 'cat.today_date';

  /// 当前命名空间（userId；未登录为 '_anon'）。bindUser 会改它并重载。
  String _ns = '_anon';

  CatNotifier() : super(const CatState()) {
    _load();
  }

  String _k(String base) => '$_ns.$base';

  /// 登录态确立时调用：切到该 userId 的命名空间并重载猫状态。
  /// 防同设备多账号串猫（审计 P1）。userId 为 null 时回到匿名命名空间。
  Future<void> bindUser(String? userId) async {
    final next = (userId == null || userId.isEmpty) ? '_anon' : userId;
    if (next == _ns) return;
    _ns = next;
    await _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = CatState(
      intimacy: prefs.getInt(_k(_keyIntimacy)) ?? 0,
      todayReviewed: prefs.getInt(_k(_keyTodayReviewed)) ?? 0,
      todayDate: prefs.getString(_k(_keyTodayDate)) ?? _todayKey(),
    );
    // 跨天复位当日计数（intimacy 不动）。
    if (state.todayDate != _todayKey()) {
      state = state.copyWith(todayReviewed: 0, todayDate: _todayKey());
      await prefs.setInt(_k(_keyTodayReviewed), 0);
      await prefs.setString(_k(_keyTodayDate), _todayKey());
    }
  }

  /// 复习评分一张卡后调：intimacy +1，当日计数 +1。
  /// 只增路径：失败/异常不回滚已加的值（正反馈不可逆，避免挫败）。
  Future<void> onCardReviewed() async {
    final next = state.copyWith(
      intimacy: state.intimacy + 1,
      todayReviewed: state.todayReviewed + 1,
    );
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_k(_keyIntimacy), next.intimacy);
    await prefs.setInt(_k(_keyTodayReviewed), next.todayReviewed);
  }

  /// 当日 0 点对齐的日期 key（YYYY-MM-DD），用于跨天复位。
  String _todayKey() {
    final n = DateTime.now();
    return '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}-'
        '${n.day.toString().padLeft(2, '0')}';
  }
}

/// 猫状态。intimacy 是历史累计（只增）；todayReviewed 是当日复习张数（跨天归零）。
class CatState {
  final int intimacy;
  final int todayReviewed;
  final String todayDate;

  const CatState({
    this.intimacy = 0,
    this.todayReviewed = 0,
    this.todayDate = '',
  });

  CatState copyWith({
    int? intimacy,
    int? todayReviewed,
    String? todayDate,
  }) =>
      CatState(
        intimacy: intimacy ?? this.intimacy,
        todayReviewed: todayReviewed ?? this.todayReviewed,
        todayDate: todayDate ?? this.todayDate,
      );

  /// 心情档位（对齐设计文档 CatMood 5 态，简化为 intimacy 阈值映射）。
  /// 阈值刻意低：1a 要让用户在前几张卡就看到猫变开心，快速感知 hook。
  CatMood get mood {
    if (intimacy <= 0) return CatMood.sleepy;
    if (intimacy < 3) return CatMood.idle;
    if (intimacy < 8) return CatMood.thinking;
    if (intimacy < 20) return CatMood.happy;
    return CatMood.encouraging;
  }

  /// 亲密度等级（展示用，每 5 张卡升一级）。
  int get level => (intimacy ~/ 5) + 1;
}

/// 猫心情（对齐设计文档 CatMood：sleepy/idle/thinking/happy/encouraging）。
/// PixelCat 据此渲染不同帧动画。
enum CatMood {
  sleepy('困困', '😴'),
  idle('发呆', '😺'),
  thinking('思考', '🤔'),
  happy('开心', '😻'),
  encouraging('打气', '🥰');

  final String label;
  final String emoji;
  const CatMood(this.label, this.emoji);
}

final catProvider = StateNotifierProvider<CatNotifier, CatState>((ref) {
  return CatNotifier();
});
