import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:uuid/uuid.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:drift/drift.dart' show Value;

/// 词书导入器：从 assets 加载词书 → 写入 drift（local-first）。
///
/// 支持两种格式（均来自 legacy 念念/MemoryCat）：
///   1. 纯 JSON 数组：[{"front":"abandon","back":"v. 放弃"}, ...]
///   2. .ncpack：zip 封装，含 manifest.json + pack.json；pack.json.decks[].cards[] = {front, back}
///
/// 复导判重：词书 id 由内容 hash 决定；同 hash 已存在则跳过（幂等）。
/// 卡 id 用 uuid（对齐 Supabase uuid 列）；新卡 fsrsState 为全新 FSRS 状态。
class DeckImporter {
  final AppDatabase db;
  static const _uuid = Uuid();

  DeckImporter(this.db);

  /// 从 asset 导入一本词书。返回 deckId；已导入过返回已有 deckId（幂等）。
  Future<String> importFromAsset(String assetPath, {String? deckName}) async {
    final bytes = await rootBundle.load(assetPath);
    final data = bytes.buffer.asUint8List();

    List<Map<String, String>> rawCards;
    String name = deckName ?? _nameFromPath(assetPath);

    if (assetPath.endsWith('.ncpack')) {
      rawCards = _parseNcPack(data);
    } else {
      rawCards = _parseJsonArray(utf8.decode(data));
    }
    if (rawCards.isEmpty) {
      throw StateError('词书 $assetPath 无卡（解析出 0 张）');
    }

    // 复导判重：内容 hash 相同 → 已导入过。
    final hash = sha256.convert(utf8.encode(
      name + rawCards.map((c) => '${c['front']}${c['back']}').join(''),
    )).toString();
    final existing = await db.getDeckByHash(hash);
    if (existing != null) return existing.id;

    final deckId = _uuid.v4();
    await db.upsertDeck(LocalDecksCompanion(
      id: Value(deckId),
      name: Value(name),
      kind: const Value('vocab'),
      contentHash: Value(hash),
      cardCount: Value(rawCards.length),
    ));

    final companions = rawCards.map((c) {
      final cardId = _uuid.v4();
      final fsrs = FsrsCard(id: cardId); // 全新卡（state=new, stability=0）
      return LocalCardsCompanion(
        id: Value(cardId),
        deckId: Value(deckId),
        type: const Value('qa'),
        front: Value(c['front'] ?? ''),
        back: Value(c['back']),
        sourceApp: const Value('niannian'),
        fsrsState: Value(jsonEncode(fsrs.toJson())),
        due: Value(fsrs.due),
        state: Value(fsrs.state.value),
        synced: const Value(false),
      );
    }).toList();
    await db.insertCards(companions);
    return deckId;
  }

  List<Map<String, String>> _parseJsonArray(String text) {
    final list = jsonDecode(text) as List;
    return list
        .map((e) => {
              'front': (e['front'] ?? '').toString(),
              'back': (e['back'] ?? '').toString(),
            })
        .where((c) => c['front']!.isNotEmpty)
        .toList();
  }

  List<Map<String, String>> _parseNcPack(List<int> zipBytes) {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final packFile = archive.files.firstWhere(
      (f) => f.name == 'pack.json',
      orElse: () => throw StateError('.ncpack 缺 pack.json'),
    );
    final packJson = jsonDecode(utf8.decode(packFile.content as List<int>));
    final decks = (packJson['decks'] as List?) ?? [];
    final out = <Map<String, String>>[];
    for (final d in decks) {
      final cards = (d['cards'] as List?) ?? [];
      for (final c in cards) {
        final front = (c['front'] ?? '').toString();
        if (front.isNotEmpty) {
          out.add({'front': front, 'back': (c['back'] ?? '').toString()});
        }
      }
    }
    return out;
  }

  String _nameFromPath(String path) {
    final file = path.split('/').last;
    return file.replaceAll(RegExp(r'\.(json|ncpack)$'), '');
  }
}
