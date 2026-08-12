import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/nuannuan/focus_provider.dart';
import 'package:uuid/uuid.dart';

/// 暖暖专注模块逻辑测试（不触 UI/网络）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  group('FocusState 纯逻辑', () {
    test('倒计时计算：totalSeconds / remainingSeconds / progress / finished', () {
      const s = FocusState(plannedMinutes: 25, elapsedSeconds: 60);
      expect(s.totalSeconds, 1500);
      expect(s.remainingSeconds, 1440);
      expect(s.finished, isFalse);
      expect(s.progress, closeTo(60 / 1500, 0.001));
      expect(const FocusState(plannedMinutes: 25, elapsedSeconds: 1500).finished, isTrue);
      expect(const FocusState(plannedMinutes: 25, elapsedSeconds: 2000).remainingSeconds, 0);
    });
  });

  group('FocusNotifier 结算', () {
    test('完成：写本地 focus_sessions(completed=true) + 触发 onCompleted（喂猫）', () async {
      var completedCalls = 0;
      FocusSession? persisted;
      final n = FocusNotifier(db,
          onCompleted: () => completedCalls++,
          onPersisted: (s) async => persisted = s);
      addTearDown(n.dispose);

      n.setPlanned(1);
      n.start();
      // 手动推进到时间到（直接 finish 模拟 _tick 到终点）。
      await n.finish();

      expect(completedCalls, 1, reason: '完成必须喂统一猫魂（onCompleted）');
      final list = await db.getTodayFocusSessions();
      expect(list.length, 1);
      expect(list.first.completed, isTrue, reason: '完成留痕 completed=true');
      expect(list.first.sourceApp, 'nuannuan');
      expect(persisted, isNotNull, reason: '完成必须异步上云回调');
      expect(persisted!.completed, isTrue);
    });

    test('放弃：写本地 focus_sessions(completed=false) + 不喂猫（软化留痕）', () async {
      var completedCalls = 0;
      final n = FocusNotifier(db, onCompleted: () => completedCalls++);
      addTearDown(n.dispose);

      n.setPlanned(1);
      n.start();
      await n.giveUp();

      expect(completedCalls, 0, reason: '放弃不喂猫（软化，不惩罚）');
      final list = await db.getTodayFocusSessions();
      expect(list.length, 1);
      expect(list.first.completed, isFalse, reason: '放弃留痕 completed=false（Forest枯树的软化版）');
    });

    test('重复 finish 幂等（done 守卫，不写重复行）', () async {
      var completedCalls = 0;
      final n = FocusNotifier(db, onCompleted: () => completedCalls++);
      addTearDown(n.dispose);
      n.setPlanned(1);
      n.start();
      await n.finish();
      await n.finish(); // 再调一次
      expect(completedCalls, 1);
      expect((await db.getTodayFocusSessions()).length, 1);
    });
  });

  group('今日总览', () {
    test('getTodayFocusSessions 只算今天的', () async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      // 插一条昨天的 + 一条今天的。
      await db.insertFocusSession(FocusSession(
        id: const Uuid().v4(), startedAt: yesterday, plannedMinutes: 25,
        actualSeconds: 1500, completed: true, sourceApp: 'nuannuan',
        synced: false, updatedAt: yesterday,
      ).toCompanion(true));
      await db.insertFocusSession(FocusSession(
        id: const Uuid().v4(), startedAt: DateTime.now(), plannedMinutes: 25,
        actualSeconds: 600, completed: true, sourceApp: 'nuannuan',
        synced: false, updatedAt: DateTime.now(),
      ).toCompanion(true));

      final today = await db.getTodayFocusSessions();
      expect(today.length, 1, reason: '只返回今天开始的会话');
      expect(today.first.actualSeconds, 600);
    });
  });
}
