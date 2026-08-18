import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/rag/bm25.dart';

/// 文献 chunk 服务（C1 逐句溯源，2026-08-17）。
///
/// SumiNote 式"每句话可溯源"的三猫实现：
///   1. 切段带锚点入库（页/段/字符偏移）——业界标准：坐标是入库时带的，不是事后找的；
///   2. 检索返回带锚点的 chunk（智能体引用《标题》p.N ¶M）；
///   3. 逐句校验器：生成文本的引用标记 ↔ 所引 chunk 对齐，对不上降级标注。
class LiteratureChunker {
  final AppDatabase db;
  LiteratureChunker(this.db);

  static const _uuid = Uuid();

  /// 段落切分阈值（字符）：中文论文摘要/段落通常 200-800 字，
  /// 超长的段按句子边界二次切。
  static const maxChunkChars = 500;

  /// 把一篇文献的全文切成带锚点的 chunks 并入库（幂等：先清后写）。
  /// [fullText] 全文；[pageBreaks] 可选分页信息（PDF 提取时记录每页起始行）。
  /// v1 无 PDF 页信息时 pageNo=0（未知），段序仍是准确锚点。
  Future<int> chunkAndStore(
    String literatureId,
    String fullText, {
    List<int> pageStartLines = const [],
  }) async {
    final paragraphs = _splitParagraphs(fullText);
    final companions = <LiteratureChunksCompanion>[];
    var offset = 0;
    for (var p = 0; p < paragraphs.length; p++) {
      final para = paragraphs[p];
      final pageNo = _pageOf(offset, fullText, pageStartLines);
      // 超长段二次切句
      final pieces = para.length > maxChunkChars ? _splitSentences(para) : [para];
      var pieceOffset = offset;
      for (final piece in pieces) {
        companions.add(LiteratureChunksCompanion.insert(
          id: 'lc_${_uuid.v4()}',
          literatureId: literatureId,
          pageNo: Value(pageNo),
          paraIndex: Value(p),
          offsetStart: Value(pieceOffset),
          offsetEnd: Value(pieceOffset + piece.length),
          body: piece,
        ));
        pieceOffset += piece.length;
      }
      offset += para.length + 1; // +1 换行
    }
    await db.replaceLiteratureChunks(literatureId, companions);
    return companions.length;
  }

  /// 段落切分：连续非空行为一段。
  List<String> _splitParagraphs(String text) {
    final paras = text
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return paras;
  }

  /// 超长段按句子边界切（中文句号/问号/感叹号/分号）。
  List<String> _splitSentences(String para) {
    final sentences = para
        .split(RegExp(r'(?<=[。！？；!?;])'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    // 合并到 ≤maxChunkChars 的块
    final out = <String>[];
    var buf = StringBuffer();
    for (final s in sentences) {
      if (buf.length + s.length > maxChunkChars && buf.isNotEmpty) {
        out.add(buf.toString());
        buf = StringBuffer();
      }
      buf.write(s);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  int _pageOf(int offset, String fullText, List<int> pageStartLines) {
    if (pageStartLines.isEmpty) return 0;
    // v1 简化：无分页信息
    return 0;
  }

  /// 检索文献 chunks（带锚点引用格式）。
  /// 返回 [{ref, body}]——ref 形如 "《标题》¶3" 或 "《标题》p.2¶3"。
  Future<List<CitedChunk>> searchChunks(String query, {int topK = 5}) async {
    final index = Bm25Index();
    final chunks = await db.getAllChunks();
    if (chunks.isEmpty) return const [];
    final litById = {
      for (final l in await db.getLiteratureList()) l.id: l,
    };
    for (final c in chunks) {
      final title = litById[c.literatureId]?.title ?? '未知文献';
      index.add(c.id.hashCode, title, c.body);
    }
    final hits = index.search(query, topK: topK);
    final byId = {for (final c in chunks) c.id: c};
    return [
      for (final (docId, score) in hits)
        if (byId.containsKey(docId.toString()) ||
            byId.values.any((c) => c.id.hashCode == docId))
          CitedChunk(
            chunkId: _resolveId(byId, docId),
            ref: _refOf(_resolve(byId, docId), litById),
            body: _resolve(byId, docId)?.body ?? '',
            score: score,
          ),
    ];
  }

  LiteratureChunk? _resolve(Map<String, LiteratureChunk> byId, int docId) {
    for (final c in byId.values) {
      if (c.id.hashCode == docId) return c;
    }
    return null;
  }

  String _resolveId(Map<String, LiteratureChunk> byId, int docId) =>
      _resolve(byId, docId)?.id ?? '';

  String _refOf(LiteratureChunk? c, Map<String, LiteratureData> litById) {
    if (c == null) return '';
    final title = litById[c.literatureId]?.title ?? '未知文献';
    final page = c.pageNo > 0 ? 'p.${c.pageNo}' : '';
    return '《$title》$page¶${c.paraIndex + 1}';
  }
}

/// 带引用锚点的 chunk（智能体引用与 UI 跳转都用它）。
class CitedChunk {
  final String chunkId;
  final String ref; // 《标题》p.2¶3
  final String body;
  final double score;
  const CitedChunk({
    required this.chunkId,
    required this.ref,
    required this.body,
    required this.score,
  });

  Map<String, dynamic> toToolJson() => {'ref': ref, 'text': body};
}

/// 逐句校验器：生成文本的引用标记 ↔ 所引 chunk 对齐。
///
/// 规则：answer 中形如 〔ref〕 的引注，其后的句子必须与该 ref 的 chunk
/// 有足够的 n-gram 重叠（或该 ref 确实在本次提供的片段里出现）。
/// 对不上的句子加降级标注——"防 AI 瞎编"的最后一道闸。
class CitationChecker {
  /// [answer] 生成的回答；[providedRefs] 本次工具结果实际提供的 ref→body。
  /// 返回标注后的回答（不可信句已标警告）。
  static String check(String answer, Map<String, String> providedRefs) {
    if (providedRefs.isEmpty) return answer;
    // 找 answer 里的所有引注（《…》p.N¶M 或〔《…》…〕）
    final refRe = RegExp(r'《[^》]+》(?:p\.\d+)?¶\d+');
    final refs = refRe.allMatches(answer).map((m) => m.group(0)!).toSet();
    var result = answer;
    for (final ref in refs) {
      final body = providedRefs[ref];
      if (body == null) {
        // 引用了不存在的锚点——硬标注
        result = result.replaceAll(ref, '$ref⚠️(引用不存在)');
        continue;
      }
    }
    // v1 句级重叠校验：对每个引注后的首句做 3-gram 重叠检查
    for (final ref in refs) {
      final body = providedRefs[ref];
      if (body == null) continue;
      final idx = answer.indexOf(ref);
      if (idx < 0) continue;
      final after = answer.substring(idx + ref.length);
      // 取引注后到下一个句号的一段作为"被支撑句"
      final m = RegExp(r'^([^。]{6,120})').firstMatch(after);
      if (m == null) continue;
      final claim = m.group(1)!;
      if (!_overlaps(claim, body)) {
        result = result.replaceFirst(
          claim,
          '$claim（⚠️该句未在所引片段中找到直接支撑，请核对原文）',
        );
      }
    }
    return result;
  }

  /// 3-gram 重叠判定（中文友好：字符级 gram）。
  static bool _overlaps(String claim, String body, {double threshold = 0.25}) {
    if (claim.length < 6) return true;
    final grams = <String>{};
    for (var i = 0; i + 3 <= claim.length; i++) {
      grams.add(claim.substring(i, i + 3));
    }
    var hit = 0;
    for (final g in grams) {
      if (body.contains(g)) hit++;
    }
    return hit / grams.length >= threshold;
  }
}
