import 'dart:math';

/// 中文 BM25 检索（架构方案 v2 P2-2，2026-08-15）。
///
/// 深研两条铁律的实现：
///  1. **CJK 分词两侧同源**——SQLite FTS5 默认按空白切，中文整句变单 token 检索废掉。
///     这里用 **bigram 滑窗**（相邻两字一组，无需词典）：写侧索引与读侧查询走同一个
///     [tokenize]，永不分叉。
///  2. **中文 BM25 无已验证基准**——效果必须配人工抽检（[explainTop] 打印 top-k 评分），
///     不能只看"不报错"。
///
/// 纯 Dart 内存倒排：考研场景（万级卡片/百级笔记）毫秒级，不引 FTS5/sqlite-vec。
/// 词书/考纲/笔记在装包/启动后由 [RagIndexer] 建索引。
class Bm25Index {
  final Map<String, Map<int, int>> _postings = {}; // term → {docId: tf}
  final List<_Doc> _docs = [];
  final Map<String, int> _docFreq = {}; // term → df
  final double _k1 = 1.5, _b = 0.75;

  bool get isEmpty => _docs.isEmpty;
  int get docCount => _docs.length;

  /// 清空（全量重建用）。
  void clear() {
    _postings.clear();
    _docs.clear();
    _docFreq.clear();
  }

  /// 中文 bigram + ASCII 词切分（写读两侧唯一入口，永不分叉）。
  ///
  /// 中文：「谢赫六法」→ [谢赫,赫六,六法]；英文/数字：小写连读成词。
  static List<String> tokenize(String text) {
    final tokens = <String>[];
    final lower = text.toLowerCase();
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        tokens.add(buf.toString());
        buf.clear();
      }
    }

    for (var i = 0; i < lower.length; i++) {
      final c = lower[i];
      final isAsciiWord = _isAsciiWordChar(c);
      if (isAsciiWord) {
        buf.write(c); // ASCII 连读
        continue;
      }
      flush();
      if (_isCjk(c)) {
        final hasPrev = i > 0 && _isCjk(lower[i - 1]);
        final hasNext = i + 1 < lower.length && _isCjk(lower[i + 1]);
        if (hasNext) {
          tokens.add(c + lower[i + 1]); // bigram
        } else if (!hasPrev) {
          // 真正孤立的汉字（前后都非汉字）作为 token，保召回
          tokens.add(c);
        }
        // 有前无后（词尾单字）：已由前一个 bigram 覆盖，不重复收
      }
    }
    flush();
    return tokens;
  }

  static bool _isCjk(String c) {
    final code = c.codeUnitAt(0);
    return code >= 0x4E00 && code <= 0x9FFF;
  }

  static bool _isAsciiWordChar(String c) {
    final code = c.codeUnitAt(0);
    return (code >= 0x61 && code <= 0x7a) || // a-z
        (code >= 0x30 && code <= 0x39); // 0-9
  }

  /// 加一个文档。docId 由调用方保证唯一（重复添加同 id 会重复计数——调用方负责判重）。
  void add(int docId, String title, String body) {
    final tokens = tokenize('$title $body');
    if (tokens.isEmpty) return;
    final tf = <String, int>{};
    for (final t in tokens) {
      tf[t] = (tf[t] ?? 0) + 1;
    }
    _docs.add(_Doc(docId, title, tokens.length));
    final docIdx = _docs.length - 1;
    for (final e in tf.entries) {
      _postings.putIfAbsent(e.key, () => {})[docIdx] = e.value;
      _docFreq[e.key] = (_docFreq[e.key] ?? 0) + 1;
    }
  }

  /// 检索：返回 (docId, score) 按 BM25 降序。
  List<(int, double)> search(String query, {int topK = 8}) {
    final qTokens = tokenize(query);
    if (qTokens.isEmpty || _docs.isEmpty) return const [];
    final avgLen = _docs.fold<double>(0, (s, d) => s + d.len) / _docs.length;
    final scores = <int, double>{};
    for (final t in qTokens) {
      final df = _docFreq[t] ?? 0;
      if (df == 0) continue;
      final idf = log((_docs.length - df + 0.5) / (df + 0.5) + 1);
      for (final e in (_postings[t] ?? const {}).entries) {
        final doc = _docs[e.key];
        final tfNorm = (e.value * (_k1 + 1)) /
            (e.value + _k1 * (1 - _b + _b * doc.len / avgLen));
        scores[e.key] = (scores[e.key] ?? 0) + idf * tfNorm;
      }
    }
    final ranked = scores.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final e in ranked.take(topK)) (_docs[e.key].docId, e.value)
    ];
  }

  /// 质量抽检（深研铁律：中文 BM25 无已验证基准，必须人工看 top-k）。
  /// 打印每命中项的 docId/得分/标题，供上线前抽样评估。
  void explainTop(String query, String Function(int docId) titleOf,
      {int topK = 5}) {
    final hits = search(query, topK: topK);
    // ignore: avoid_print
    print('[BM25 抽检] "$query" top${hits.length}:');
    for (final (docId, score) in hits) {
      // ignore: avoid_print
      print('  $score  #$docId  ${titleOf(docId)}');
    }
  }
}

class _Doc {
  final int docId;
  final String title;
  final int len;
  const _Doc(this.docId, this.title, this.len);
}
