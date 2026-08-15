import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/core/rag/bm25.dart';

/// RAG 索引器（P2-2）：把五猫内容灌进 Bm25Index，供智能体检索"他自己的资料"。
///
/// 文档源：念念卡（front+back）、知知笔记/考纲（title+content）。
/// docId 编码：卡=deck 卡 uuid 哈希——不直接可逆，但 [RagIndexer.docTitleOf]
/// 维护 docId→可读标题映射，智能体展示引用时用标题。
/// 重建时机：装包后/冷启动后（[rebuild]）；万级卡毫秒级，无需增量。
class RagIndexer {
  final AppDatabase db;
  final Bm25Index _index = Bm25Index();
  final Map<int, String> _titles = {};

  RagIndexer(this.db);

  bool get isReady => !_index.isEmpty;

  /// 全量重建（幂等：清空重建）。装包后/冷启动调用。
  Future<void> rebuild() async {
    _index.clear();
    _titles.clear();
    var nextId = 1;
    // 念念卡
    final cards = await db.select(db.localCards).get();
    for (final c in cards) {
      final id = nextId++;
      _index.add(id, c.front, c.back ?? '');
      _titles[id] = c.front;
    }
    // 知知笔记/考纲
    final notes = await db.getNotes();
    for (final n in notes) {
      final id = nextId++;
      _index.add(id, n.title, n.content);
      _titles[id] = n.title;
    }
  }

  /// 检索：返回 (标题, 得分) top-k。
  List<(String, double)> search(String query, {int topK = 8}) {
    return [
      for (final (docId, score) in _index.search(query, topK: topK))
        (_titles[docId] ?? '#$docId', score)
    ];
  }

  /// 质量抽检（深研铁律：中文 BM25 上线前人工看 top-k）。
  void explainTop(String query, {int topK = 5}) {
    _index.explainTop(query, (id) => _titles[id] ?? '#$id', topK: topK);
  }
}

/// 全局单例：冷启动 bootstrap 时 rebuild 一次；装包后调用 rebuild。
final ragIndexProvider = Provider<RagIndexer>((ref) {
  return RagIndexer(ref.watch(appDatabaseProvider));
});

/// 修订号：rebuild 后自增，消费方（智能体工具）watch 刷新。
final ragRevisionProvider = StateProvider<int>((ref) => 0);
