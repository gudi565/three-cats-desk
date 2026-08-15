import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:uuid/uuid.dart';

import 'deck_providers.dart';

/// 跨猫卡箱：其它模块（稳稳错题 / 知知笔记 / 渊渊高亮）→ 念念复习池的统一入口。
///
/// 关键：确保 deckId 非 null——卡在 drift 里 deckId=null 会进不了念念任何词书列表（不可见）。
/// 所以先确保存在「跨猫卡箱」词书，再把卡挂进去。
/// 写完上云（cards 表，type/source_app 由调用方定；source_app 须被 source_app_write_ok 允许）。
class CrossAppCards {
  static const boxName = '跨猫卡箱';
  static const _uuid = Uuid();

  /// 加一张跨 App 卡到念念复习池。返回卡 id。
  /// [ref] 用动态类型以同时接受 provider 层的 Ref 与 screen 层的 WidgetRef（两者都有 read()）。
  static Future<String> add(
    dynamic ref, {
    required String front,
    required String back,
    required String sourceApp, // wenwen / zhizhi / yuanyuan
    String type = 'qa',        // qa / error / highlight
    String? sourceRef,
  }) async {
    final db = ref.read(appDatabaseProvider);
    final deckId = await _ensureBoxDeck(db);

    final cardId = _uuid.v4();
    final fsrs = FsrsCard(id: cardId);
    await db.insertCards([
      LocalCardsCompanion(
        id: Value(cardId),
        deckId: Value(deckId),
        type: Value(type),
        front: Value(front),
        back: Value(back),
        sourceApp: Value(sourceApp),
        fsrsState: Value(jsonEncode(fsrs.toJson())),
        due: Value(fsrs.due),
        state: Value(fsrs.state.value),
        synced: const Value(false),
      ),
    ]);

    // 上云（cards 表）
    final card = LocalCard(
      id: cardId, deckId: deckId, type: type, front: front, back: back,
      sourceApp: sourceApp, fsrsState: jsonEncode(fsrs.toJson()),
      due: fsrs.due, state: fsrs.state.value, synced: false, updatedAt: DateTime.now(),
    );
    await ref.read(cloudSyncProvider).pushCard(card, fsrs);

    // 触发念念 deck 列表刷新（新卡进跨猫卡箱）
    ref.read(deckRevisionProvider.notifier).state++;
    return cardId;
  }

  /// 确保存在「跨猫卡箱」词书，返回其 id。没有则创建。
  static Future<String> _ensureBoxDeck(AppDatabase db) async {
    final decks = await db.getAllDecks();
    for (final d in decks) {
      if (d.name == boxName) return d.id;
    }
    final id = _uuid.v4();
    await db.upsertDeck(LocalDecksCompanion(
      id: Value(id),
      name: const Value(boxName),
      kind: const Value('glossary'),
      builtIn: const Value(false),
      cardCount: const Value(0),
    ));
    return id;
  }
}
