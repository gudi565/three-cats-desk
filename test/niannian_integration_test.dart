import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/fsrs.dart';

// 念念最小闭环集成测试：导入词书 → drift 有卡 → 取今日到期 → FSRS 评分 → 卡状态更新。
// 不依赖云（local-first），验证 Phase0 验收的本地部分。
void main() {
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
}

Map<String, dynamic> _decode(String s) => jsonDecode(s) as Map<String, dynamic>;
String _encode(FsrsCard c) => jsonEncode(c.toJson());
