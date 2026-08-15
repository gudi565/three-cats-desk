import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/rag/bm25.dart';
import 'package:three_cats_desk/core/rag/rag_indexer.dart';
import 'package:three_cats_desk/features/agent/tools/cat_tools.dart';
import 'dart:convert';

/// 中文 BM25（bigram）+ RagIndexer 验证（P2-2）。
///
/// 深研铁律落地：①分词写读同源（tokenize 唯一入口）②中文效果无已验证基准 →
/// 测试即抽检：搜"谢赫六法"必须命中中国画论卡/考纲（业务级断言，非只看"不报错"）。
void main() {
  group('Bm25Index 分词', () {
    test('中文 bigram：谢赫六法 → [谢赫,赫六,六法]', () {
      expect(Bm25Index.tokenize('谢赫六法'), ['谢赫', '赫六', '六法']);
    });

    test('ASCII 连读成词 + 大小写归一', () {
      expect(Bm25Index.tokenize('FSRS algorithm'), ['fsrs', 'algorithm']);
    });

    test('混合文本两侧同源（写读一个函数）', () {
      final t = Bm25Index.tokenize('考研英语 core vocabulary');
      expect(t, contains('考研')); // bigram
      expect(t, contains('core'));
    });
  });

  group('Bm25Index 检索', () {
    test('相关性排序：命中词多的文档排前', () {
      final idx = Bm25Index();
      idx.add(1, '马原笔记', '矛盾的普遍性与特殊性的关系');
      idx.add(2, '美术史', '谢赫六法与气韵生动');
      idx.add(3, '英语词汇', 'abandon 放弃');

      final hits = idx.search('谢赫六法');
      expect(hits.first.$1, 2); // 美术史命中全部 bigram
      expect(idx.search('abandon').first.$1, 3);
      expect(idx.search('量子力学'), isEmpty); // 无命中不炸
    });
  });

  group('RagIndexer 全链路（真实考纲数据）', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      // 词书+卡
      await db.upsertDeck(LocalDecksCompanion.insert(
          id: 'd1', name: '中国画论', contentHash: const Value('h1')));
      final fsrs1 = '{"id":"c1"}';
      await db.insertCards([
        LocalCardsCompanion.insert(
            id: 'c1',
            deckId: const Value('d1'),
            front: '谢赫六法',
            back: const Value('气韵生动/骨法用笔/应物象形/随类赋彩/经营位置/传移模写'),
            fsrsState: fsrs1,
            due: Value(DateTime.now()),
            state: const Value(0)),
        LocalCardsCompanion.insert(
            id: 'c2',
            deckId: const Value('d1'),
            front: '三远法',
            back: const Value('高远/深远/平远（郭熙《林泉高致》）'),
            fsrsState: fsrs1,
            due: Value(DateTime.now()),
            state: const Value(0)),
      ]);
      // 考纲笔记
      await db.upsertNote(NotesCompanion.insert(
        id: 'syl',
        title: const Value('美术考研 · 考纲'),
        content: const Value('## 中国画论\n- 谢赫六法：气韵生动为首\n## 美学\n- 意境与典型'),
        subject: const Value('美术史论'),
      ));
    });
    tearDown(() async => db.close());

    test('搜"谢赫六法"命中卡片与考纲（业务级抽检断言）', () async {
      final rag = RagIndexer(db);
      await rag.rebuild();
      expect(rag.isReady, isTrue);

      final hits = rag.search('谢赫六法');
      expect(hits, isNotEmpty);
      final titles = hits.map((h) => h.$1).toSet();
      expect(titles.contains('谢赫六法'), isTrue, reason: '卡片应命中');
      // 考纲也应在 top 命中里
      expect(hits.take(5).any((h) => h.$1.contains('考纲')), isTrue);
    });

    test('search_knowledge 工具：JSON 结果含命中标题', () async {
      final rag = RagIndexer(db);
      await rag.rebuild();
      final tool = SearchKnowledgeTool(rag);
      final data = jsonDecode(await tool.execute({'query': '三远'})) as Map<String, dynamic>;
      final hits = data['hits'] as List;
      expect(hits, isNotEmpty);
      expect(hits.first['title'], contains('三远'));
    });

    test('空知识库 → 工具返回友好错误（不炸）', () async {
      final rag = RagIndexer(db); // 未 rebuild
      final tool = SearchKnowledgeTool(rag);
      final data = jsonDecode(await tool.execute({'query': 'x'})) as Map<String, dynamic>;
      expect(data['error'], contains('尚未就绪'));
    });
  });
}
