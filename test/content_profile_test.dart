import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/profile/content_profile.dart';
import 'package:three_cats_desk/core/importers/quiz_importer.dart';

/// Profile 内容包机制（按人定制的引擎）行为验证。
///
/// 钉死：profile.yaml 解析 / 模块开关 / 内容导入闭环（词书+题库+考纲笔记进 drift，幂等）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileLoader.parse', () {
    test('解析完整 profile.yaml（含模块清单与内容路径）', () {
      const yaml = '''
id: kaoyan_art
displayName: 美术考研 · 国美方向
suggestSchool: 中国美术学院
suggestMajor: 美术史论
modules: [niannian, wenwen, zhizhi]
decks: [decks/a.ncpack, decks/b.ncpack]
questions: [q.json]
syllabus: syllabus.md
''';
      final p = ProfileLoader.parse(yaml, basePath: 'assets/profiles/kaoyan_art')!;
      expect(p.id, 'kaoyan_art');
      expect(p.displayName, '美术考研 · 国美方向');
      expect(p.suggestSchool, '中国美术学院');
      expect(p.modules, ['niannian', 'wenwen', 'zhizhi']);
      expect(p.decks, ['decks/a.ncpack', 'decks/b.ncpack']);
      expect(p.questions, ['q.json']);
      expect(p.syllabus, 'syllabus.md');
    });

    test('modules 缺省 → 默认五猫全开', () {
      final p = ProfileLoader.parse('id: x\n', basePath: 'd')!;
      expect(p.modules,
          ['niannian', 'nuannuan', 'wenwen', 'zhizhi', 'yuanyuan']);
    });

    test('非法 yaml → null（调用方回落 standard）', () {
      expect(ProfileLoader.parse('::: not yaml :::', basePath: 'd'), isNull);
    });
  });

  group('ContentProfile 模块开关（task #8）', () {
    test('hasModule 按 modules 清单判定', () {
      const p = ContentProfile(
        id: 't', displayName: 't', basePath: '',
        modules: ['niannian', 'wenwen'],
      );
      expect(p.hasModule('niannian'), isTrue);
      expect(p.hasModule('wenwen'), isTrue);
      expect(p.hasModule('yuanyuan'), isFalse);
    });

    test('standard 兜底：五猫全开且有公共课词书', () {
      final s = ContentProfile.standard;
      expect(s.hasModule('yuanyuan'), isTrue);
      expect(s.decks, isNotEmpty);
      expect(s.questions, isNotEmpty);
    });
  });

  group('ProfileImporter 内容导入闭环', () {
    test('导入词书+题库+考纲进 drift，重复导入幂等', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final importer = ProfileImporter(db, DeckImporter(db), QuizImporter(db));
      const p = ContentProfile(
        id: 'kaoyan_art', displayName: '美术考研', basePath: 'assets/profiles/kaoyan_art',
        modules: ['niannian', 'wenwen', 'zhizhi'],
        decks: ['assets/profiles/kaoyan_art/decks/中国画论.ncpack'],
        questions: ['assets/profiles/kaoyan_art/questions.json'],
        syllabus: 'assets/profiles/kaoyan_art/syllabus.md',
        suggestMajor: '美术史论',
      );
      final r1 = await importer.importProfile(p);
      expect(r1['decks'], 1); // 中国画论
      expect((r1['questions'] as int) > 0, isTrue); // sample-quiz 20题
      expect(r1['syllabus'], isTrue); // 考纲笔记已建

      // 词书进 drift
      final decks = await db.getAllDecks();
      expect(decks.any((d) => d.name.contains('中国画论')), isTrue);
      // 题库进 drift
      expect(await db.countQuestions(), greaterThan(0));
      // 考纲 → 知知笔记（标题含 displayName·考纲）
      final notes = await db.getNotes();
      expect(notes.any((n) => n.title.contains('考纲')), isTrue);
      expect(notes.firstWhere((n) => n.title.contains('考纲')).content,
          contains('谢赫六法'));

      // 幂等：再导一次，词书/题库/考纲不翻倍
      final deckCountBefore = decks.length;
      final qCountBefore = await db.countQuestions();
      final noteCountBefore = notes.length;
      final r2 = await importer.importProfile(p);
      expect(r2['syllabus'], isFalse); // 考纲已存在，不重建
      expect((await db.getAllDecks()).length, deckCountBefore);
      expect(await db.countQuestions(), qCountBefore);
      expect((await db.getNotes()).length, noteCountBefore);
      await db.close();
    });
  });
}
