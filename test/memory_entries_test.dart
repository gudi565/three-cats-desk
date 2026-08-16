import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/backup_service.dart';
import 'package:three_cats_desk/core/db/database.dart';

/// 画像存储（MemoryEntries）+ 备份闭环验证（M1）。
void main() {
  test('四槽写入→按槽读取正序→清槽', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    await db.insertMemory(MemoryEntriesCompanion.insert(
        id: 'm1', slot: 'scope', body: '在 5 次做题中，马原矛盾类错 3 次：练习中'));
    await db.insertMemory(MemoryEntriesCompanion.insert(
        id: 'm2', slot: 'scope', body: '在 12 次做题中，英语词汇对 11 次：已掌握'));
    await db.insertMemory(MemoryEntriesCompanion.insert(
        id: 'm3', slot: 'preferences', body: '喜欢简短讲解，先结论后展开'));

    final scope = await db.getMemories('scope');
    expect(scope.map((m) => m.id).toList(), ['m1', 'm2']); // 正序
    expect(scope.first.body, contains('练习中')); // 三态标记在
    expect((await db.getMemories('preferences')).length, 1);

    await db.clearSlot('scope');
    expect((await db.getMemories('scope')), isEmpty);
    expect((await db.getMemories('preferences')).length, 1); // 其它槽不动
  });

  test('preferences 判重（空白归一 casefold）——DeepTutor 幂等同款', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    await db.insertMemory(MemoryEntriesCompanion.insert(
        id: 'm1', slot: 'preferences', body: '喜欢 简短  讲解'));

    // 空白/大小写不同 → 判重命中
    expect(await db.findDuplicatePreference('喜欢 简短 讲解'), isNotNull);
    expect(await db.findDuplicatePreference('喜欢 简短  讲解。'), isNull); // 词间空格数不同=同一句；增字=不同句
    expect(await db.findDuplicatePreference('完全不同的话'), isNull);
  });

  test('备份闭环：画像随备份迁移（换机画像不丢）', () async {
    final db1 = AppDatabase.forTesting(NativeDatabase.memory());
    await db1.insertMemory(MemoryEntriesCompanion.insert(
        id: 'm1',
        slot: 'scope',
        body: '在 5 次做题中，马原薄弱：练习中',
        refs: const Value('wenwen:attempts')));
    final json = await BackupService(db1).exportToJson();
    await db1.close();

    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db2.close());
    final counts = await BackupService(db2).importFromJson(json);
    expect(counts['memoryEntries'], 1);
    final restored = await db2.getMemories('scope');
    expect(restored.single.body, contains('马原'));
    expect(restored.single.refs, 'wenwen:attempts');
  });
}
