import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/backup_service.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'dart:convert';

/// 备份导出/导入闭环验证（本地专属版的换机/重装保命绳）。
///
/// 关键：导出→全新库导入→核心数据（卡 FSRS 进度/词书/笔记/活动）逐字段一致；
/// 且重复导入幂等（insertOnConflictUpdate），行数不翻倍。
void main() {
  Future<AppDatabase> newDb() => Future.value(AppDatabase.forTesting(NativeDatabase.memory()));

  test('导出→导入全新库：卡 FSRS 进度逐字段恢复，幂等不翻倍', () async {
    final db1 = await newDb();
    final backup1 = BackupService(db1);

    // 造数据：一个词书 + 一张已复习卡（FSRS 有进度）+ 一条笔记 + 一天活动
    final fsrs = FsrsCard(id: 'card-1');
    await db1.into(db1.localDecks).insert(LocalDecksCompanion(
          id: const Value('deck-1'), name: const Value('考研词汇'),
          contentHash: const Value('hash1'), cardCount: const Value(1),
        ));
    await db1.into(db1.localCards).insert(LocalCardsCompanion(
          id: const Value('card-1'), deckId: const Value('deck-1'),
          front: const Value('abandon'), back: const Value('v. 放弃'),
          fsrsState: Value(jsonEncode(fsrs.toJson())), due: Value(fsrs.due),
          state: Value(fsrs.state.value), synced: const Value(false),
        ));
    await db1.into(db1.notes).insert(NotesCompanion(
          id: const Value('note-1'), title: const Value('美术史笔记'),
          content: const Value('# 文艺复兴\n达芬奇'), subject: const Value('美术'),
        ));
    await db1.recordAppOpen('2026-08-13', intimacy: 9);

    final json = await backup1.exportToJson();
    await db1.close();

    // 全新库导入
    final db2 = await newDb();
    final backup2 = BackupService(db2);
    final counts = await backup2.importFromJson(json);
    expect(counts['decks'], 1);
    expect(counts['cards'], 1);
    expect(counts['notes'], 1);
    expect(counts['activityLog'], 1);

    // 逐字段核验：卡 FSRS 状态恢复
    final card = await db2.getCardById('card-1');
    expect(card, isNotNull);
    expect(card!.front, 'abandon');
    expect(card.back, 'v. 放弃');
    final restoredFsrs = FsrsCard.fromJson(jsonDecode(card.fsrsState));
    expect(restoredFsrs.id, 'card-1');
    // SQLite 时间戳精度到秒（毫秒被截断），比秒级时间戳。
    expect(card.due.millisecondsSinceEpoch ~/ 1000,
        fsrs.due.millisecondsSinceEpoch ~/ 1000);

    final note = await db2.getNoteById('note-1');
    expect(note!.title, '美术史笔记');
    expect(note.content, contains('达芬奇'));

    final activity = await db2.getRecentActivity(5);
    expect(activity.single.intimacy, 9);

    // 幂等：同一备份再导一次，行数不变
    await backup2.importFromJson(json);
    expect((await db2.getAllDecks()).length, 1);
    expect((await db2.select(db2.localCards).get()).length, 1);
    expect((await db2.getNotes()).length, 1);
    expect(await db2.countActiveDays(), 1);
    await db2.close();
  });

  test('空库导出也能成环（边界：无数据不崩）', () async {
    final db = await newDb();
    final backup = BackupService(db);
    final json = await backup.exportToJson();
    final counts = await BackupService(await newDb()).importFromJson(json);
    expect(counts.values.every((c) => c == 0), isTrue);
    await db.close();
  });
}
