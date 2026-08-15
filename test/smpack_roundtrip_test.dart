import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:three_cats_desk/core/cross_app_cards.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/profile/pack_installer.dart';
import 'package:three_cats_desk/core/profile/profile_notifier.dart';
import 'package:three_cats_desk/core/importers/quiz_importer.dart';

/// 生成器→安装器 全链路往返测试（客户交付模式质量门，2026-08-14）。
///
/// 钉死闭环：tool/make_pack.dart 产出的**真实** .smpack 字节 →
/// PackInstaller 装进全新库 → 词书/题库/考纲全部落库 + profile 激活 +
/// 幂等重装不翻倍 + 恢复已装包激活态。
/// 这是"客户点一下就完成内置"的最终保障。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final packFile = File('build/packs/kaoyan_art.smpack');

  // 生成器产物不存在时提示先跑（CI 里 build-pack job 会先生成）。
  setUpAll(() {
    if (!packFile.existsSync()) {
      Process.runSync('dart', [
        'run', 'tool/make_pack.dart', 'tool/packs/kaoyan_art.yaml',
      ]);
    }
    expect(packFile.existsSync(), isTrue, reason: '先生成 .smpack 再测往返');
  });

  test('真实 .smpack 安装：五猫内容全部落库 + 摘要正确', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final installer =
        PackInstaller(db, DeckImporter(db), QuizImporter(db));

    final result = await installer.installFromBytes(packFile.readAsBytesSync());

    // 摘要与生成器输出一致（7 词书 1842 卡 20 题考纲）
    expect(result.decks, 7);
    expect(result.questions, 20);
    expect(result.syllabus, isTrue);
    expect(result.profile.displayName, '美术考研 · 国美方向');
    expect(result.profile.suggestSchool, '中国美术学院');
    expect(result.profile.examDate, '2026-12-26');
    expect(result.failedDecks, isEmpty);

    // 词书全落库且卡可复习（念念可用）
    final decks = await db.getAllDecks();
    expect(decks.length, 7);
    expect(decks.any((d) => d.name.contains('中外美术史')), isTrue);
    final anyDeck = decks.firstWhere((d) => d.name.contains('中外美术史'));
    final due = await db.getDueCards(anyDeck.id);
    expect(due.length, 335); // 新卡全今日到期

    // 题库落库（稳稳可用）
    expect(await db.countQuestions(), 20);

    // 考纲 → 知知笔记（条目可转念念卡）
    final notes = await db.getNotes();
    expect(notes.any((n) => n.title.contains('考纲')), isTrue);
    expect(notes.firstWhere((n) => n.title.contains('考纲')).content,
        contains('谢赫六法'));
  });

  test('幂等：重复安装同一包不翻倍', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final installer =
        PackInstaller(db, DeckImporter(db), QuizImporter(db));
    final bytes = packFile.readAsBytesSync();

    await installer.installFromBytes(bytes);
    final decksBefore = (await db.getAllDecks()).length;
    final qBefore = await db.countQuestions();
    final notesBefore = (await db.getNotes()).length;

    final r2 = await installer.installFromBytes(bytes);
    expect((await db.getAllDecks()).length, decksBefore); // contentHash 判重
    expect(await db.countQuestions(), qBefore); // id 判重（幂等 upsert）
    expect((await db.getNotes()).length, notesBefore); // 考纲标题判重
    expect(r2.syllabus, isFalse); // 第二次不重建考纲笔记
  });

  test('坏包防御：非 zip / 缺 profile.yaml 抛 PackFormatException', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final installer =
        PackInstaller(db, DeckImporter(db), QuizImporter(db));

    expect(() => installer.installFromBytes([1, 2, 3, 4, 5]), // 非 zip
        throwsA(isA<PackFormatException>()));
  });

  test('ProfileNotifier.applyPack 激活 + 冷启动恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());
    final notifier = ProfileNotifier(db, DeckImporter(db), QuizImporter(db));

    // 初始 = standard 通用原型
    expect(notifier.state.id, 'standard');
    expect(notifier.hasCustomPack, isFalse);

    // 安装真实包 → 激活
    final result =
        await notifier.applyPack(packFile.readAsBytesSync());
    expect(notifier.state.id, 'kaoyan_art');
    expect(notifier.hasCustomPack, isTrue);
    expect(notifier.hasModule('yuanyuan'), isTrue);
    expect(result.decks, 7);

    // 模拟冷启动：新 notifier 从 SharedPreferences 恢复激活态
    final restored = ProfileNotifier(db, DeckImporter(db), QuizImporter(db));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(restored.state.id, 'kaoyan_art');
    expect(restored.state.suggestSchool, '中国美术学院');
    expect(restored.hasCustomPack, isTrue);

    // 装了包之后 standard 公共课不会重复导入（contentHash 判重）
    await restored.loadAndImport();
    expect((await db.getAllDecks()).length, 7);
  });
}
