import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';

/// 知知笔记模块逻辑测试（不触 UI/网络）。CRUD + 归档 + 今日计数。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  Note makeNote(String id, {String title = '标题', String content = '正文'}) => Note(
        id: id, title: title, content: content, subject: '政治',
        sourceApp: 'zhizhi', synced: false, archived: false,
        updatedAt: DateTime.now(), createdAt: DateTime.now(),
      );

  test('笔记 CRUD：新建→读→改→归档（软删）', () async {
    await db.upsertNote(makeNote('n1', title: '马原笔记').toCompanion(true));
    var notes = await db.getNotes();
    expect(notes.length, 1);
    expect(notes.first.title, '马原笔记');

    // 改
    await db.upsertNote(makeNote('n1', title: '马原笔记·改').toCompanion(true));
    expect((await db.getNoteById('n1'))!.title, '马原笔记·改');
    expect((await db.getNotes()).length, 1, reason: 'upsert by id 不重复');

    // 归档（软删）
    await db.archiveNote('n1');
    expect((await db.getNotes()).length, 0, reason: '归档后从列表消失');
  });

  test('今日笔记计数', () async {
    await db.upsertNote(makeNote('n1').toCompanion(true));
    await db.upsertNote(makeNote('n2').toCompanion(true));
    expect(await db.getTodayNoteCount(), 2);
  });

  test('未上云笔记队列（synced=false）', () async {
    await db.upsertNote(makeNote('n1').toCompanion(true));
    expect((await db.getUnsyncedNotes()).length, 1);
    await db.markNoteSynced('n1');
    expect((await db.getUnsyncedNotes()).length, 0);
  });
}
