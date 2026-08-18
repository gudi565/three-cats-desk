import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/fsrs.dart';

// 念念最小闭环集成测试：导入词书 → drift 有卡 → 取今日到期 → FSRS 评分 → 卡状态更新。
// 不依赖云（local-first），验证 Phase0 验收的本地部分。
void main() {
  c2SiblingTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DeckImporter importer;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    importer = DeckImporter(db);
  });
  tearDown(() => db.close());

  test('导入 .ncpack 词书 → drift 有 deck + 卡，今日全部到期', () async {
    // importer.importFromAsset 用 rootBundle，测试环境已 register assets
    final deckId = await importer.importFromAsset('assets/decks/熟词僻义.ncpack',
        deckName: '熟词僻义');
    final decks = await db.getAllDecks();
    expect(decks.length, 1);
    expect(decks.first.name, '熟词僻义');
    expect(decks.first.cardCount, greaterThan(0));

    final due = await db.getDueCards(deckId);
    expect(due.length, decks.first.cardCount); // 新卡全部今日到期
  });

  test('复导同本词书幂等（contentHash 判重，不重复）', () async {
    await importer.importFromAsset('assets/decks/熟词僻义.ncpack');
    await importer.importFromAsset('assets/decks/熟词僻义.ncpack'); // 再导一次
    final decks = await db.getAllDecks();
    expect(decks.length, 1); // 不重复
  });

  test('FSRS 评分后：drift 卡更新、due 推后、synced=false', () async {
    final deckId = await importer.importFromAsset('assets/decks/english-kaoyan-hifi.json',
        deckName: '考研英语高频');
    final before = (await db.getDueCards(deckId)).first;
    expect(before.synced, isFalse); // 新导入未同步

    const fsrs = Fsrs();
    final card = FsrsCard.fromJson(_decode(before.fsrsState));
    // 评分 good
    final updated = fsrs.schedule(card, FsrsRating.good);
    await db.updateCardFsrs(before.id, _encode(updated), updated.due,
        updated.state.value,
        synced: false);

    final after = (await db.getCardById(before.id))!;
    final afterCard = FsrsCard.fromJson(_decode(after.fsrsState));
    expect(afterCard.reps, 1);
    expect(afterCard.state, FsrsState.review); // good 新卡直接 review
    expect(after.due.isAfter(DateTime.now()), isTrue); // due 推到未来
    expect(after.synced, isFalse);
  });

  test('JSON 与 ncpack 两格式都解析出卡', () async {
    final jsonId = await importer.importFromAsset('assets/decks/english-kaoyan-hifi.json');
    final ncpackId = await importer.importFromAsset('assets/decks/考研英语核心词组.ncpack');
    final jsonCards = await db.countCardsInDeck(jsonId);
    final ncpackCards = await db.countCardsInDeck(ncpackId);
    expect(jsonCards, greaterThan(50));
    expect(ncpackCards, greaterThan(20));
  });

  // 雷1 回归测试：getDueCards 必须按天对齐——今天到期的卡今天任何时刻都算到期，
  // 明天到期的卡今天不算（即使"明天的时刻"还没到）。
  test('雷1回归：getDueCards 按天对齐（今天的卡整天可见，明天的不算）', () async {
    final deckId = await importer.importFromAsset('assets/decks/熟词僻义.ncpack');
    final now = DateTime(2026, 8, 12, 10, 0, 0); // 固定 now = 今天 10:00

    // 插三张卡：due=今天 14:30（晚于 now 但仍今天，应到期）、due=昨天（应到期）、due=明天（不应到期）。
    final cards = [
      _card('c-today', deckId, DateTime(2026, 8, 12, 14, 30)),
      _card('c-yesterday', deckId, DateTime(2026, 8, 11, 9, 0)),
      _card('c-tomorrow', deckId, DateTime(2026, 8, 13, 8, 0)),
    ];
    await db.insertCards(cards);

    final due = await db.getDueCards(deckId, now: now);
    final dueIds = due.map((c) => c.id).toSet();

    // 内置词书的新卡 due=now(真实当前时间 2026-08-12) 也算到期，但我们只断言插入的三张的归属。
    expect(dueIds.contains('c-today'), isTrue,
        reason: 'due=今天14:30 的卡，今天10:00打开必须算到期（雷1：原实现因时分秒比较漏掉）');
    expect(dueIds.contains('c-yesterday'), isTrue, reason: '昨天的卡必须到期');
    expect(dueIds.contains('c-tomorrow'), isFalse, reason: '明天到期的卡今天不该出现');
  });
}

LocalCardsCompanion _card(String id, String deckId, DateTime due) =>
    LocalCardsCompanion(
      id: Value(id),
      deckId: Value(deckId),
      front: Value('f-$id'),
      back: Value('b-$id'),
      fsrsState: Value('{}'),
      due: Value(due),
      state: const Value(2),
      synced: const Value(false),
    );

Map<String, dynamic> _decode(String s) => jsonDecode(s) as Map<String, dynamic>;
String _encode(FsrsCard c) => jsonEncode(c.toJson());

// ── C2 sibling 埋卡 ──
void c2SiblingTests() {
  group('C2 sibling 埋卡（Anki 同源卡 session 内不重复出现）', () {
    test('答过 noteId=A 的卡后，getDueCards 排除同 noteId 卡', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final fsrs = FsrsCard(id: 'x');
      await db.upsertDeck(LocalDecksCompanion.insert(
          id: 'd1', name: '测试', contentHash: const Value('h1')));
      await db.insertCards([
        LocalCardsCompanion.insert(
            id: 'c1', deckId: const Value('d1'), noteId: const Value('noteA'),
            front: '挖空1', fsrsState: '{"id":"c1"}',
            due: Value(fsrs.due), state: const Value(0)),
        LocalCardsCompanion.insert(
            id: 'c2', deckId: const Value('d1'), noteId: const Value('noteA'),
            front: '挖空2（同源）', fsrsState: '{"id":"c2"}',
            due: Value(fsrs.due), state: const Value(0)),
        LocalCardsCompanion.insert(
            id: 'c3', deckId: const Value('d1'), noteId: const Value('noteB'),
            front: '无关卡', fsrsState: '{"id":"c3"}',
            due: Value(fsrs.due), state: const Value(0)),
      ]);
      // 不排除：3 张全在
      expect((await db.getDueCards('d1')).length, 3);
      // 排除 noteA：只剩 c3
      final filtered = await db.getDueCards('d1', excludeNoteIds: {'noteA'});
      expect(filtered.map((c) => c.id).toList(), ['c3']);
      // 空排除集 = 不排除
      expect((await db.getDueCards('d1', excludeNoteIds: {})).length, 3);
    });
  });
}
