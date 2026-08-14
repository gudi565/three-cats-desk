import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:yaml/yaml.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/features/wenwen/quiz_importer.dart';

/// 客户内容包 Profile（按人定制的引擎，2026-08-13）。
///
/// 核心理念：**客户版和标准版只差 assets 内容 + 一个 profile，代码零分叉。**
/// 100 个客户也只有 1 份代码库——差异全部数据驱动。
///
/// 每个 profile 是一个 assets 目录（如 `assets/profiles/kaoyan_art/`），内含：
///   profile.yaml      — 档案（昵称建议/院校/专业/启用的猫/内容清单）
///   decks/*.ncpack    — 念念词书/背诵卡（复用 DeckImporter，contentHash 判重）
///   questions/*.json  — 稳稳题库（复用 QuizImporter，id 判重）
///   syllabus.md       — 考纲（知知预置笔记，条目可转念念卡）
///   literature.json   — 渊渊预置文献包（可选）
///
/// profile.yaml  schema：
///   id: kaoyan_art
///   displayName: 美术考研 · 国美方向
///   suggestSchool: 中国美术学院
///   suggestMajor: 美术史论
///   modules: [niannian, nuannuan, wenwen, zhizhi, yuanyuan]   # 启用哪些猫
///   decks: [decks/中外美术史.ncpack, decks/艺术概论.ncpack]
///   questions: [questions/政治核心.json, questions/英语词汇.json]
///   syllabus: syllabus.md
///   literature: literature.json
class ContentProfile {
  final String id;
  final String displayName;
  final String suggestSchool;
  final String suggestMajor;
  final List<String> modules; // 启用的猫：niannian/nuannuan/wenwen/zhizhi/yuanyuan
  final List<String> decks;
  final List<String> questions;
  final String syllabus;
  final String literature;
  final String basePath; // assets 目录前缀，如 assets/profiles/kaoyan_art

  const ContentProfile({
    required this.id,
    required this.displayName,
    this.suggestSchool = '',
    this.suggestMajor = '',
    this.modules = const ['niannian', 'nuannuan', 'wenwen', 'zhizhi', 'yuanyuan'],
    this.decks = const [],
    this.questions = const [],
    this.syllabus = '',
    this.literature = '',
    required this.basePath,
  });

  /// 是否启用某只猫（模块开关，task #8 用）。
  bool hasModule(String module) => modules.contains(module);

  /// 标准通用版（无定制内容，公共课词书+示例题库，全部猫启用）。
  /// 这是 profile 缺失/未选时的兜底——保证 App 永远可用。
  static const standard = ContentProfile(
    id: 'standard',
    displayName: '通用版',
    basePath: '',
    modules: ['niannian', 'nuannuan', 'wenwen', 'zhizhi', 'yuanyuan'],
    decks: [
      'assets/decks/熟词僻义.ncpack',
      'assets/decks/考研英语核心词组.ncpack',
      'assets/decks/english-kaoyan-hifi.json',
    ],
    questions: ['assets/questions/sample-quiz.json'],
  );
}

/// 加载 profile.yaml（从 assets）。目录不存在/无 yaml → 返回 null（调用方回落 standard）。
class ProfileLoader {
  /// 解析 profile.yaml 文本为 ContentProfile。测试可直接调（不依赖 rootBundle）。
  static ContentProfile? parse(String yamlText, {required String basePath}) {
    try {
      final doc = loadYaml(yamlText);
      if (doc is! YamlMap) return null;
      List<String> strList(Object? v) =>
          v is YamlList ? v.map((e) => e.toString()).toList() : const [];
      return ContentProfile(
        id: (doc['id'] ?? '').toString(),
        displayName: (doc['displayName'] ?? doc['id'] ?? '').toString(),
        suggestSchool: (doc['suggestSchool'] ?? '').toString(),
        suggestMajor: (doc['suggestMajor'] ?? '').toString(),
        modules: strList(doc['modules']).isEmpty
            ? const ['niannian', 'nuannuan', 'wenwen', 'zhizhi', 'yuanyuan']
            : strList(doc['modules']),
        decks: strList(doc['decks']),
        questions: strList(doc['questions']),
        syllabus: (doc['syllabus'] ?? '').toString(),
        literature: (doc['literature'] ?? '').toString(),
        basePath: basePath,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从 assets 目录加载 profile.yaml。相对路径（decks/questions 等）拼上 basePath。
  static Future<ContentProfile?> loadFromAssets(String profileDir) async {
    try {
      final text = await rootBundle.loadString('$profileDir/profile.yaml');
      final p = parse(text, basePath: profileDir);
      if (p == null) return null;
      // 相对路径 → 完整 asset 路径
      String full(String rel) => rel.startsWith('assets/') ? rel : '$profileDir/$rel';
      return ContentProfile(
        id: p.id,
        displayName: p.displayName,
        suggestSchool: p.suggestSchool,
        suggestMajor: p.suggestMajor,
        modules: p.modules,
        decks: p.decks.map(full).toList(),
        questions: p.questions.map(full).toList(),
        syllabus: p.syllabus.isEmpty ? '' : full(p.syllabus),
        literature: p.literature.isEmpty ? '' : full(p.literature),
        basePath: profileDir,
      );
    } catch (_) {
      return null; // 目录/yaml 不存在 → 调用方回落 standard
    }
  }
}

/// 把 profile 的内容幂等导入 drift（词书 contentHash 判重 / 题 id 判重 / 考纲笔记按标题判重）。
/// 全部单失败不阻塞其它（一本词书坏了不挡题库）。
class ProfileImporter {
  final AppDatabase db;
  final DeckImporter deckImporter;
  final QuizImporter quizImporter;
  ProfileImporter(this.db, this.deckImporter, this.quizImporter);

  /// 导入 profile 全部内容。返回导入摘要（词书数/题数/考纲笔记是否建）。
  Future<Map<String, Object>> importProfile(ContentProfile p) async {
    var deckCount = 0, questionCount = 0;
    for (final path in p.decks) {
      try {
        await deckImporter.importFromAsset(path);
        deckCount++;
      } catch (_) {/* 单本失败跳过 */}
    }
    for (final path in p.questions) {
      try {
        questionCount += await quizImporter.importFromAsset(path);
      } catch (_) {/* 单题库失败跳过 */}
    }
    var syllabusNote = false;
    if (p.syllabus.isNotEmpty) {
      syllabusNote = await _importSyllabus(p);
    }
    return {
      'decks': deckCount,
      'questions': questionCount,
      'syllabus': syllabusNote,
      'modules': p.modules,
    };
  }

  /// 考纲 → 知知预置笔记（标题判重，重复导入不重建）。考纲条目后续可一键转念念卡。
  Future<bool> _importSyllabus(ContentProfile p) async {
    try {
      final text = await rootBundle.loadString(p.syllabus);
      final title = '${p.displayName} · 考纲';
      // 判重：已有同标题笔记则跳过（幂等）
      final existing = await db.getNotes();
      if (existing.any((n) => n.title == title)) return false;
      await db.upsertNote(NotesCompanion.insert(
        id: 'syllabus-${p.id}',
        title: Value(title),
        content: Value(text),
        subject: Value(p.suggestMajor.isEmpty ? '考纲' : p.suggestMajor),
        sourceApp: const Value('zhizhi'),
      ));
      return true;
    } catch (_) {
      return false;
    }
  }
}
