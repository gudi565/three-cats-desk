import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';

/// activity_log 本地留存度量表行为验证（本地部署方向的观测仪器）。
///
/// 无云端后「用户用没用」的唯一信号源。钉死：
///   recordAppOpen 幂等递增 / recordReviewed 计数 / 活跃天数统计 / 跨天独立成行。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
  });

  test('recordAppOpen 首次建行，同日再调只递增 openCount', () async {
    await db.recordAppOpen('2026-08-13', intimacy: 5);
    await db.recordAppOpen('2026-08-13', intimacy: 7);
    await db.recordAppOpen('2026-08-13', intimacy: 7);
    final rows = await db.getRecentActivity(10);
    expect(rows, hasLength(1));
    expect(rows.single.day, '2026-08-13');
    expect(rows.single.openCount, 3);
    expect(rows.single.intimacy, 7); // 快照取最新
    expect(rows.single.firstOpenedAt, isNotNull);
    expect(rows.single.lastOpenedAt, isNotNull);
  });

  test('跨天独立成行，活跃天数正确统计', () async {
    await db.recordAppOpen('2026-08-11');
    await db.recordAppOpen('2026-08-12');
    await db.recordAppOpen('2026-08-13');
    await db.recordAppOpen('2026-08-13'); // 同日重复
    expect(await db.countActiveDays(), 3);
    final recent = await db.getRecentActivity(2);
    expect(recent.map((r) => r.day).toList(), ['2026-08-13', '2026-08-12']); // 倒序
  });

  test('recordReviewed 累计当日复习张数，无行时保底建行', () async {
    await db.recordReviewed('2026-08-13', intimacy: 1);
    await db.recordReviewed('2026-08-13', intimacy: 2);
    final rows = await db.getRecentActivity(5);
    expect(rows.single.reviewed, 2);
    expect(rows.single.intimacy, 2);
  });

  test('同一天的打开与复习合并到同一行', () async {
    await db.recordAppOpen('2026-08-13', intimacy: 0);
    await db.recordReviewed('2026-08-13', intimacy: 1);
    await db.recordReviewed('2026-08-13', intimacy: 2);
    final rows = await db.getRecentActivity(5);
    expect(rows, hasLength(1));
    expect(rows.single.openCount, 1);
    expect(rows.single.reviewed, 2);
  });
}
