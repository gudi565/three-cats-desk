import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';
import 'package:yaml/yaml.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/features/wenwen/quiz_importer.dart';
import 'content_profile.dart';

/// .smpack 资源包运行时安装器（客户交付模式，2026-08-14）。
///
/// 交付流：卖家用 tool/make_pack.dart 按客户专业生成 .smpack 发给客户 →
/// 客户在通用原型 App 里点一下导入 → 五猫内容全部就位。
///
/// .smpack = zip：
///   profile.yaml      — id/displayName/suggestSchool/suggestMajor/examDate/modules/decks/questions/syllabus/literature
///   decks/*.ncpack    — 念念词书（contentHash 判重）
///   questions/*.json  — 稳稳题库（id 判重）
///   syllabus.md       — 考纲（知知预置笔记，标题判重）
///   literature.json   — 渊渊预置文献包（DOI 判重，可选）
///
/// 安装全幂等、单项失败不阻塞（一本词书坏了不挡题库），
/// 返回 [PackInstallResult] 摘要给 UI 弹「已装：词书×N · 题目×M · 考纲 · 文献×K」。
class PackInstaller {
  final AppDatabase db;
  final DeckImporter deckImporter;
  final QuizImporter quizImporter;
  PackInstaller(this.db, this.deckImporter, this.quizImporter);

  /// 安装一个 .smpack（字节流来自 file_picker / 网络 / 测试）。
  /// 解析失败（非 zip / 缺 profile.yaml）抛 [PackFormatException]，UI 提示"不是有效的资源包"。
  Future<PackInstallResult> installFromBytes(List<int> bytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw PackFormatException('无法解压（不是有效的三猫资源包文件）');
    }
    final profileFile = archive.find('profile.yaml');
    if (profileFile == null) {
      throw PackFormatException('资源包缺少 profile.yaml（不是有效的三猫资源包）');
    }
    final profile = ProfileLoader.parse(
      utf8.decode(profileFile.content as List<int>),
      basePath: '',
    );
    if (profile == null) {
      throw PackFormatException('profile.yaml 解析失败');
    }

    var deckCount = 0, questionCount = 0;
    final failedDecks = <String>[];
    for (final entry in archive.files) {
      final name = entry.name.split('/').last; // 兼容 zip 内带目录前缀
      if (entry.isFile && (name.endsWith('.ncpack') || name.endsWith('.json'))) {
        // questions 由清单驱动；decks 也按清单驱动更可控——先按扩展名+目录归类
        final inDecksDir = entry.name.contains('decks/');
        final inQuestionsDir = entry.name.contains('questions/');
        final data = entry.content as List<int>;
        try {
          if (inQuestionsDir && name.endsWith('.json')) {
            questionCount += await quizImporter.importFromBytes(data);
          } else if (inDecksDir) {
            await deckImporter.importFromBytes(data,
                name: _stripExt(name), isNcPack: name.endsWith('.ncpack'));
            deckCount++;
          }
        } catch (_) {
          if (inDecksDir) failedDecks.add(_stripExt(name));
          // 单项失败不阻塞：题库坏了跳过，词书继续
        }
      }
    }

    var syllabusInstalled = false;
    final syllabusFile = archive.find('syllabus.md');
    if (syllabusFile != null) {
      syllabusInstalled = await _installSyllabusNote(
        profile,
        utf8.decode(syllabusFile.content as List<int>),
      );
    }

    var litCount = 0;
    final litFile = archive.find('literature.json');
    if (litFile != null) {
      litCount = await _installLiterature(utf8.decode(litFile.content as List<int>));
    }

    return PackInstallResult(
      profile: profile,
      decks: deckCount,
      questions: questionCount,
      syllabus: syllabusInstalled,
      literature: litCount,
      failedDecks: failedDecks,
    );
  }

  /// 考纲 → 知知预置笔记（标题判重；重复装同一包不重建）。
  Future<bool> _installSyllabusNote(ContentProfile p, String text) async {
    final title = '${p.displayName} · 考纲';
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
  }

  /// 渊渊预置文献（DOI 判重；手动录入 source=manual）。铁律：文献来自真实条目，非 AI 造。
  /// literature.json = [{"title","authors","year","venue","doi","url","abstract"}, ...]
  Future<int> _installLiterature(String jsonText) async {
    List<dynamic> list;
    try {
      list = jsonDecode(jsonText) as List;
    } catch (_) {
      return 0;
    }
    var n = 0;
    const uuid = Uuid();
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final doi = (m['doi'] ?? '').toString();
      if (doi.isNotEmpty) {
        final existing = await db.getLiteratureByDoi(doi);
        if (existing != null) continue; // DOI 判重
      }
      await db.upsertLiterature(LiteratureCompanion.insert(
        id: 'lit-${uuid.v4()}',
        title: (m['title'] ?? '').toString(),
        authors: Value((m['authors'] ?? '').toString()),
        year: Value((m['year'] ?? '').toString()),
        venue: Value((m['venue'] ?? '').toString()),
        doi: Value(doi),
        url: Value((m['url'] ?? '').toString()),
        abstractText: Value((m['abstract'] ?? '').toString()),
        source: const Value('manual'),
        sourceApp: const Value('yuanyuan'),
      ));
      n++;
    }
    return n;
  }

  String _stripExt(String name) =>
      name.replaceAll(RegExp(r'\.(ncpack|json)$'), '');
}

/// 安装结果摘要（UI 弹窗用）。
class PackInstallResult {
  final ContentProfile profile;
  final int decks;
  final int questions;
  final bool syllabus;
  final int literature;
  final List<String> failedDecks; // 解析失败的词书名（提示但不阻塞）
  PackInstallResult({
    required this.profile,
    required this.decks,
    required this.questions,
    required this.syllabus,
    required this.literature,
    this.failedDecks = const [],
  });

  /// 摘要文案：「美术考研 · 国美方向：词书×7 · 题目×20 · 考纲 · 文献×5」
  String get summary {
    final parts = <String>[
      '词书×$decks',
      '题目×$questions',
      if (syllabus) '考纲',
      if (literature > 0) '文献×$literature',
    ];
    return '${profile.displayName}：${parts.join(' · ')}';
  }
}

/// 包格式错误（非 zip / 缺 profile.yaml / yaml 坏）。
class PackFormatException implements Exception {
  final String message;
  PackFormatException(this.message);
  @override
  String toString() => message;
}

extension _ArchiveFind on Archive {
  /// 按文件名（忽略目录前缀）找第一个文件。
  ArchiveFile? find(String fileName) {
    for (final f in files) {
      if (f.isFile && f.name.split('/').last == fileName) return f;
    }
    return null;
  }
}
