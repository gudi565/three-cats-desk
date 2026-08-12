import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';

/// 渊渊文献模块逻辑测试（不触网络/UI）。DOI 去重 + CRUD + 归档 + 未同步队列。
/// 真实检索（CrossRef）是网络调用，这里不测；测本地文献库逻辑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  test('文献 CRUD：加入→读→按 DOI 去重', () async {
    await db.upsertLiterature(LiteratureCompanion.insert(
      id: 'l1', title: '注意力机制综述', doi: const Value('10.1000/x1'),
    ));
    var list = await db.getLiteratureList();
    expect(list.length, 1);
    expect(list.first.title, '注意力机制综述');
    expect(list.first.authors, ''); // insert 未传则用表默认

    // 同 DOI 去重（检索命中已入库）
    final existing = await db.getLiteratureByDoi('10.1000/x1');
    expect(existing, isNotNull, reason: '按 DOI 能查到已入库文献');

    // 不同 DOI 是另一篇
    await db.upsertLiterature(LiteratureCompanion.insert(
      id: 'l2', title: '另一篇', doi: const Value('10.1000/x2'),
    ));
    expect((await db.getLiteratureList()).length, 2);
  });

  test('归档（软删）从列表消失', () async {
    await db.upsertLiterature(LiteratureCompanion.insert(id: 'l1', title: 'A'));
    await db.archiveLiterature('l1');
    expect((await db.getLiteratureList()).length, 0);
  });

  test('我的批注更新 + 未同步队列', () async {
    await db.upsertLiterature(LiteratureCompanion.insert(id: 'l1', title: 'A'));
    expect((await db.getUnsyncedLiterature()).length, 1);
    await db.updateLiteratureNote('l1', '这段很重要');
    expect((await db.getLiteratureById('l1'))!.note, '这段很重要');
    await db.markLiteratureSynced('l1');
    expect((await db.getUnsyncedLiterature()).length, 0);
  });
}

