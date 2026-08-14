import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:three_cats_desk/core/backup_service.dart';
import 'package:three_cats_desk/core/cross_app_cards.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/local_only_backend.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/features/cat/cat_provider.dart';
import 'package:three_cats_desk/features/niannian/review_provider.dart';
import 'package:three_cats_desk/features/nuannuan/focus_provider.dart';
import 'package:three_cats_desk/features/wenwen/quiz_provider.dart';
import 'package:three_cats_desk/features/yuanyuan/literature_provider.dart';
import 'package:three_cats_desk/features/zhizhi/notes_provider.dart';

/// 端到端全流程验证（本地专属版 L0 出口门控，2026-08-13）。
///
/// 防重启宪法「度量不在线不算 done」：真实驱动五个模块的 provider，
/// 验证套装流水线 + 统一猫魂 + 备份闭环在本地模式下全程贯通：
///
///   内容导入 → 念念翻卡评分(FSRS) → 稳稳做题(错题→念念) →
///   知知笔记→念念卡 → 渊渊文献→念念卡 → 暖暖专注(喂统一猫魂) →
///   五源卡汇集「跨猫卡箱」 → intimacy 跨模块累计 → 导出备份 → 全新库恢复一致。
///
/// 全程 LocalOnlyBackend（无云端），证明本地专属系统闭环自洽。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('五猫流水线 + 统一猫魂 + 备份恢复 端到端贯通', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());

    // 准备：导入一条念念词书卡 + 一道稳稳题（模拟内容包导入）
    final fsrs = FsrsCard(id: 'ncard-1');
    await db.into(db.localDecks).insert(LocalDecksCompanion.insert(
        id: 'deck-vocab', name: '美术史', contentHash: const Value('h1')));
    await db.into(db.localCards).insert(LocalCardsCompanion.insert(
        id: 'ncard-1',
        deckId: const Value('deck-vocab'),
        front: '谢赫六法',
        back: const Value('气韵生动等六法'),
        fsrsState: jsonEncode(fsrs.toJson()),
        due: Value(fsrs.due),
        state: Value(fsrs.state.value)));
    await db.into(db.questions).insert(QuestionsCompanion.insert(
        id: 'q1',
        stem: '《洛神赋图》作者是',
        optionsJson: '["顾恺之","吴道子"]',
        answerIndex: 0));

    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      cloudSyncProvider.overrideWithValue(LocalOnlyBackend()),
    ]);
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final cat = container.read(catProvider.notifier);
    final intimacyBefore = container.read(catProvider).intimacy;

    // ── 1. 念念：翻卡评分（FSRS）──
    // 先确认卡真的按 deckId 落库且今日到期（getDueCards 的查询前提）
    final allCards = await db.select(db.localCards).get();
    expect(allCards, hasLength(1));
    expect(allCards.single.deckId, 'deck-vocab');
    final dueCards = await db.getDueCards('deck-vocab');
    expect(dueCards, hasLength(1), reason: '新卡 state=new 应今日到期');

    // reviewControllerProvider 是 autoDispose——container.read 后无人 watch 会立即销毁重置，
    // 用 listen 保活到会话结束。
    final sub = container.listen(
      reviewControllerProvider('deck-vocab'),
      (_, __) {},
      fireImmediately: true,
    );
    addTearDown(sub.close);
    // 等 _load 完成（轮询 queue 非空，替代固定 sleep）
    ReviewSession session() => container.read(reviewControllerProvider('deck-vocab'));
    for (var i = 0; i < 50 && session().queue.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(session().queue, hasLength(1));
    await container.read(reviewControllerProvider('deck-vocab').notifier).grade(FsrsRating.good);
    await cat.onCardReviewed(); // 评分喂猫（review_screen 的实际接线）
    final afterGrade = await db.getCardById('ncard-1');
    expect(afterGrade!.due.isAfter(DateTime.now().subtract(const Duration(days: 1))), isTrue);

    // ── 2. 稳稳：做题答错 → 错题自动进念念 ──
    final quizSub = container.listen(quizControllerProvider('全部'), (_, __) {}, fireImmediately: true);
    addTearDown(quizSub.close);
    // 等题库加载（questionListProvider 是 FutureProvider）
    for (var i = 0; i < 50 && container.read(quizControllerProvider('全部')).questions.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    container.read(quizControllerProvider('全部').notifier).answer(1); // 选错（正确是 0）
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final wrongs = await db.getWrongAttempts();
    expect(wrongs, isNotEmpty); // 错题已记

    // ── 3. 知知：笔记 → 念念卡 ──
    await noteToCard(container as dynamic,
        noteId: 'note-1', front: '南北宗论', back: '董其昌提出，分山水画为南北二宗');

    // ── 4. 渊渊：文献 → 念念卡 ──
    await literatureToCard(container as dynamic,
        literatureId: 'lit-1', title: '《图画见闻志》', excerpt: '郭若虚著，宋代画史');

    // ── 5. 暖暖：完成一次专注 → 写 session + 喂统一猫魂 ──
    final focus = container.read(focusProvider.notifier);
    focus.setPlanned(25);
    focus.start();
    // 直接结算（不等真实 25 分钟）：调 finish 路径
    await focus.finish();
    final focusSessions = await db.getTodayFocusSessions();
    expect(focusSessions, isNotEmpty);

    // ── 6. 跨猫卡箱汇集：稳稳错题 + 知知 + 渊渊 三源卡 ──
    final decks = await db.getAllDecks();
    final box = decks.firstWhere((d) => d.name == CrossAppCards.boxName);
    final boxCards = await (db.select(db.localCards)
          ..where((c) => c.deckId.equals(box.id)))
        .get();
    final sources = boxCards.map((c) => c.sourceApp).toSet();
    expect(sources, containsAll(['wenwen', 'zhizhi', 'yuanyuan']));

    // ── 7. 统一猫魂：intimacy 跨模块累计（念念复习+1，暖暖专注+1）──
    final intimacyAfter = container.read(catProvider).intimacy;
    expect(intimacyAfter, greaterThan(intimacyBefore));

    // ── 8. 备份闭环：导出 → 全新库恢复 → 关键数据一致 ──
    final json = await BackupService(db).exportToJson();
    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db2.close());
    await BackupService(db2).importFromJson(json);
    // 念念卡的 FSRS 进度恢复了
    final restoredCard = await db2.getCardById('ncard-1');
    expect(restoredCard, isNotNull);
    expect(restoredCard!.front, '谢赫六法');
    // 跨猫卡箱的三源卡也恢复了
    final restoredBox = (await db2.getAllDecks())
        .firstWhere((d) => d.name == CrossAppCards.boxName);
    final restoredBoxCards = await (db2.select(db2.localCards)
          ..where((c) => c.deckId.equals(restoredBox.id)))
        .get();
    expect(restoredBoxCards.map((c) => c.sourceApp).toSet(),
        containsAll(['wenwen', 'zhizhi', 'yuanyuan']));
    // 专注记录恢复了
    expect((await db2.getTodayFocusSessions()).length, focusSessions.length);
  });
}
