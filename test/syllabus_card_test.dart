import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/cross_app_cards.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/local_only_backend.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/features/zhizhi/notes_provider.dart';

/// 考纲结构化→念念卡（用户点名功能）链路验证。
///
/// 考纲预置为知知笔记（ProfileImporter._importSyllabus）后，
/// 考纲条目（或任意笔记内容）经 noteToCard → 跨猫卡箱 → 念念复习队列。
/// 钉死：笔记内容能转成 type=qa / source_app=zhizhi 的卡，且落在「跨猫卡箱」词书里（deckId 非 null 可见）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('noteToCard：笔记/考纲条目 → 念念跨猫卡箱（type=qa, source_app=zhizhi）', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      cloudSyncProvider.overrideWithValue(LocalOnlyBackend()),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });

    // 模拟知知编辑器「转复习卡」：取考纲条目首行作 front，要点作 back。
    await noteToCard(container as dynamic,
        noteId: 'syllabus-kaoyan_art',
        front: '谢赫六法',
        back: '气韵生动/骨法用笔/应物象形/随类赋彩/经营位置/传移模写');

    // 卡落进「跨猫卡箱」词书（deckId 非 null，念念可见）
    final decks = await db.getAllDecks();
    final box = decks.firstWhere((d) => d.name == CrossAppCards.boxName);
    final cards = await (db.select(db.localCards)
          ..where((c) => c.deckId.equals(box.id)))
        .get();
    expect(cards, hasLength(1));
    expect(cards.single.front, '谢赫六法');
    expect(cards.single.back, contains('气韵生动'));
    expect(cards.single.type, 'qa');
    expect(cards.single.sourceApp, 'zhizhi');

    // 今日到期（新卡 state=new 立即可复习）→ 证明进了念念复习队列
    final due = await db.getDueCards(box.id);
    expect(due, hasLength(1));
  });
}
