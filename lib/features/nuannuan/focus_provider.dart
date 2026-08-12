import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:uuid/uuid.dart';

import '../cat/cat_provider.dart';

/// 专注会话状态（纯计时，本地）。
class FocusState {
  final int plannedMinutes;
  final int elapsedSeconds;
  final bool running;   // 计时中
  final bool done;      // 已结算（完成或放弃）

  const FocusState({
    this.plannedMinutes = 25,
    this.elapsedSeconds = 0,
    this.running = false,
    this.done = false,
  });

  int get totalSeconds => plannedMinutes * 60;
  int get remainingSeconds => (totalSeconds - elapsedSeconds).clamp(0, totalSeconds);
  bool get finished => elapsedSeconds >= totalSeconds;
  double get progress => totalSeconds == 0 ? 0 : elapsedSeconds / totalSeconds;

  FocusState copyWith({int? plannedMinutes, int? elapsedSeconds, bool? running, bool? done}) =>
      FocusState(
        plannedMinutes: plannedMinutes ?? this.plannedMinutes,
        elapsedSeconds: elapsedSeconds ?? this.elapsedSeconds,
        running: running ?? this.running,
        done: done ?? this.done,
      );
}

/// 暖暖专注计时器（番茄钟）。
///
/// 闭环：start → 每秒 tick → finish(完成) / giveUp(放弃)。
///   完成/放弃都写本地 focus_sessions（local-first）+ 异步上云。
///   完成 → onCompleted（喂统一猫魂 intimacy+，跨模块共享——暖暖和念念喂同一只猫）。
///   放弃 → 软化留痕（completed=false），不调猫（不惩罚，"猫等你回来"）。
class FocusNotifier extends StateNotifier<FocusState> {
  final AppDatabase db;
  final Future<void> Function(FocusSession session)? onPersisted; // 上云回调（cloud_sync 注入）
  final void Function()? onCompleted; // 完成回调（猫 provider 注入）

  Timer? _timer;
  String? _sessionId;
  DateTime? _startedAt;
  static const _uuid = Uuid();

  FocusNotifier(this.db, {this.onPersisted, this.onCompleted}) : super(const FocusState());

  /// 选计划时长（仅在未开始时）。
  void setPlanned(int minutes) {
    if (state.running || state.done) return;
    state = state.copyWith(plannedMinutes: minutes, elapsedSeconds: 0);
  }

  void start() {
    if (state.running || state.finished) return;
    _sessionId ??= _uuid.v4();
    _startedAt ??= DateTime.now();
    state = state.copyWith(running: true, done: false);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void pause() {
    _timer?.cancel();
    state = state.copyWith(running: false);
  }

  void _tick() {
    if (!state.running) return;
    final next = state.elapsedSeconds + 1;
    state = state.copyWith(elapsedSeconds: next);
    if (next >= state.totalSeconds) {
      finish();
    }
  }

  /// 完成（时间到 / 手动提前完成）。写本地 + 上云 + 喂猫。
  Future<void> finish() async {
    if (state.done) return;
    _timer?.cancel();
    await _settle(completed: true);
    onCompleted?.call(); // 喂统一猫魂（intimacy+，跨模块）
  }

  /// 放弃（软化留痕：completed=false，不惩罚，不喂猫）。写本地 + 上云。
  Future<void> giveUp() async {
    if (state.done) return;
    _timer?.cancel();
    await _settle(completed: false);
  }

  /// 重新开始（结算后重置）。
  void reset() {
    _timer?.cancel();
    _sessionId = null;
    _startedAt = null;
    state = FocusState(plannedMinutes: state.plannedMinutes);
  }

  Future<void> _settle({required bool completed}) async {
    final session = FocusSession(
      id: _sessionId ?? _uuid.v4(),
      startedAt: _startedAt ?? DateTime.now(),
      plannedMinutes: state.plannedMinutes,
      actualSeconds: state.elapsedSeconds,
      completed: completed,
      sourceApp: 'nuannuan',
      synced: false,
      updatedAt: DateTime.now(),
    );
    await db.insertFocusSession(session.toCompanion(true));
    state = state.copyWith(running: false, done: true);
    // 异步上云（不阻塞；未登录/失败静默，local-first 不破）。
    final cb = onPersisted;
    if (cb != null) unawaited(cb(session));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final focusProvider = StateNotifierProvider.autoDispose<FocusNotifier, FocusState>((ref) {
  return FocusNotifier(
    ref.watch(appDatabaseProvider),
    onPersisted: (s) => ref.read(cloudSyncProvider).pushFocusSession(s),
    onCompleted: () => ref.read(catProvider.notifier).onFocusCompleted(),
  );
});

/// 今日专注总览（HomeScreen 仪表盘用）。完成分钟数 + 完成次数。
final todayFocusProvider = FutureProvider.autoDispose<({int minutes, int sessions})>((ref) async {
  final list = await ref.watch(appDatabaseProvider).getTodayFocusSessions();
  final doneSec = list.where((s) => s.completed).fold<int>(0, (a, s) => a + s.actualSeconds);
  return (minutes: (doneSec / 60).round(), sessions: list.where((s) => s.completed).length);
});
