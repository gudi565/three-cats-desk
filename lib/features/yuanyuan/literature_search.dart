import 'dart:convert';

import 'package:http/http.dart' as http;

/// 渊渊 · 文献检索服务（真实公开 API，绝不 AI 造文献——铁律）。
///
/// 用 CrossRef REST API（免费、无需 key、跨平台含 Web）：真实学术论文元数据。
/// RAG「问你的文献」依赖后端 pgvector，未部署 → 诚实留口（检索仍可用）。
class CrossRefHit {
  final String title;
  final String authors;
  final String year;
  final String venue;
  final String doi;
  final String url;
  final String abstractText;

  const CrossRefHit({
    required this.title,
    this.authors = '',
    this.year = '',
    this.venue = '',
    this.doi = '',
    this.url = '',
    this.abstractText = '',
  });
}

class LiteratureSearchService {
  static const _base = 'https://api.crossref.org/works';

  /// 检索 CrossRef。返回真实命中文献（最多 limit 条）。失败/无网返回空（降级）。
  Future<List<CrossRefHit>> search(String query, {int limit = 10}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    try {
      final uri = Uri.parse(_base).replace(queryParameters: {
        'query.bibliographic': q,
        'rows': '$limit',
        'select': 'title,author,published,container-title,DOI,URL,abstract',
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) return [];
      final obj = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final items = (obj['message']?['items'] as List?) ?? [];
      return items.map((it) => _toHit(it as Map<String, dynamic>))
          .where((h) => h.title.isNotEmpty)
          .toList();
    } catch (_) {
      return []; // 网络/解析失败 → 空（不阻塞）
    }
  }

  CrossRefHit _toHit(Map<String, dynamic> it) {
    final titleList = it['title'] as List?;
    final title = (titleList != null && titleList.isNotEmpty) ? titleList.first.toString() : '';
    // 作者：family, given
    final authorList = it['author'] as List?;
    final authors = (authorList ?? [])
        .map((a) => '${(a['family'] ?? '')}'.trim())
        .where((s) => s.isNotEmpty)
        .take(4)
        .join(', ');
    // 年份
    final issued = it['issued'] ?? it['published'];
    String year = '';
    if (issued is Map && issued['date-parts'] is List) {
      final dp = issued['date-parts'] as List;
      if (dp.isNotEmpty && dp[0] is List && (dp[0] as List).isNotEmpty) {
        year = '${(dp[0] as List)[0]}';
      }
    }
    final container = it['container-title'] as List?;
    final venue = (container != null && container.isNotEmpty) ? container.first.toString() : '';
    return CrossRefHit(
      title: title,
      authors: authors,
      year: year,
      venue: venue,
      doi: (it['DOI'] ?? '').toString(),
      url: (it['URL'] ?? '').toString(),
      abstractText: _stripHtml((it['abstract'] ?? '').toString()),
    );
  }

  String _stripHtml(String s) =>
      s.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll('&amp;', '&').trim();
}
