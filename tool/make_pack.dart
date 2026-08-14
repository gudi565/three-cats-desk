// 三猫书桌 · .smpack 资源包生成器（卖家端 CLI，2026-08-14）。
//
// 用法（在 three-cats-desk/ 下）：
//   dart run tool/make_pack.dart tool/packs/kaoyan_art.yaml
//   dart run tool/make_pack.dart tool/packs/my_client.yaml -o 客户-张三.smpack
//
// 配置 yaml（tool/packs/*.yaml）：
//   id: kaoyan_art
//   displayName: 美术考研 · 国美方向
//   suggestSchool: 中国美术学院
//   suggestMajor: 美术史论
//   examDate: 2026-12-26        # 可选
//   modules: [niannian, nuannuan, wenwen, zhizhi, yuanyuan]  # 可选，缺省全开
//   decks:                       # 词书路径（.ncpack/.json，可指向 04_内容与题库）
//     - /abs/or/rel/path/中外美术史.ncpack
//   questions: [path/quiz.json]  # 可选
//   syllabus: path/syllabus.md   # 可选
//   literature: path/lit.json    # 可选
//
// 质量门（生成前强制校验，不通过不出包）：
//   - 每本词书必须能解析且卡数 > 0
//   - 题库每道题 id/stem/options>=2/answerIndex 合法（复用 App 同款解析规则）
//   - examDate 格式 YYYY-MM-DD
//   - 输出摘要：词书×N(卡数)/题目×M/考纲/文献×K + 文件大小
import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:yaml/yaml.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/make_pack.dart <config.yaml> [-o output.smpack]');
    exit(2);
  }
  final configPath = args[0];
  String? outPath;
  final oi = args.indexOf('-o');
  if (oi >= 0 && oi + 1 < args.length) outPath = args[oi + 1];

  final cfgFile = File(configPath);
  if (!cfgFile.existsSync()) {
    stderr.writeln('✗ 配置文件不存在: $configPath');
    exit(1);
  }
  final doc = loadYaml(cfgFile.readAsStringSync());
  if (doc is! YamlMap || (doc['id'] ?? '').toString().isEmpty) {
    stderr.writeln('✗ 配置缺 id');
    exit(1);
  }

  List<String> paths(String key) => (doc[key] is YamlList)
      ? (doc[key] as YamlList).map((e) => e.toString()).toList()
      : const [];

  final archive = Archive();
  var totalCards = 0, deckCount = 0, questionCount = 0;

  // ── 词书（校验 + 打包）──
  for (final rel in paths('decks')) {
    final f = _resolve(configPath, rel);
    if (f == null) {
      stderr.writeln('✗ 词书不存在: $rel');
      exit(1);
    }
    final bytes = f.readAsBytesSync();
    final name = f.uri.pathSegments.last;
    final cards = _countDeckCards(bytes, name);
    if (cards <= 0) {
      stderr.writeln('✗ 质量门不过：词书「$name」解析出 0 张卡');
      exit(1);
    }
    totalCards += cards;
    deckCount++;
    archive.addFile(ArchiveFile('decks/$name', bytes.length, bytes));
    stdout.writeln('  ✓ decks/$name（$cards 卡）');
  }

  // ── 题库（校验 + 打包）──
  for (final rel in paths('questions')) {
    final f = _resolve(configPath, rel);
    if (f == null) {
      stderr.writeln('✗ 题库不存在: $rel');
      exit(1);
    }
    final bytes = f.readAsBytesSync();
    final name = f.uri.pathSegments.last;
    final n = _validateQuestions(bytes, name);
    questionCount += n;
    archive.addFile(ArchiveFile('questions/$name', bytes.length, bytes));
    stdout.writeln('  ✓ questions/$name（$n 题）');
  }

  // ── 考纲 / 文献（原样打包）──
  String? syllabusRel = doc['syllabus']?.toString();
  if (syllabusRel != null && syllabusRel.isNotEmpty) {
    final f = _resolve(configPath, syllabusRel);
    if (f == null) {
      stderr.writeln('✗ 考纲不存在: $syllabusRel');
      exit(1);
    }
    final bytes = f.readAsBytesSync();
    archive.addFile(ArchiveFile('syllabus.md', bytes.length, bytes));
    stdout.writeln('  ✓ syllabus.md（${(bytes.length / 1024).toStringAsFixed(1)}KB）');
  }
  String? litRel = doc['literature']?.toString();
  var litCount = 0;
  if (litRel != null && litRel.isNotEmpty) {
    final f = _resolve(configPath, litRel);
    if (f == null) {
      stderr.writeln('✗ 文献包不存在: $litRel');
      exit(1);
    }
    final bytes = f.readAsBytesSync();
    litCount = (jsonDecode(utf8.decode(bytes)) as List).length;
    archive.addFile(ArchiveFile('literature.json', bytes.length, bytes));
    stdout.writeln('  ✓ literature.json（$litCount 条）');
  }

  // ── profile.yaml（校验 examDate + 写入）──
  final examDate = (doc['examDate'] ?? '').toString();
  if (examDate.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(examDate)) {
    stderr.writeln('✗ examDate 格式应为 YYYY-MM-DD: $examDate');
    exit(1);
  }
  final yamlOut = StringBuffer()
    ..writeln('# 由 tool/make_pack.dart 生成，勿手改')
    ..writeln('id: ${doc['id']}')
    ..writeln('displayName: ${doc['displayName'] ?? doc['id']}')
    ..writeln('suggestSchool: ${doc['suggestSchool'] ?? ''}')
    ..writeln('suggestMajor: ${doc['suggestMajor'] ?? ''}');
  if (examDate.isNotEmpty) yamlOut.writeln('examDate: $examDate');
  final modules = paths('modules');
  yamlOut.writeln('modules: [${modules.isEmpty
      ? 'niannuan, nuannuan, wenwen, zhizhi, yuanyuan' : modules.join(', ')}]');
  final yamlBytes = utf8.encode(yamlOut.toString());
  archive.addFile(ArchiveFile('profile.yaml', yamlBytes.length, yamlBytes));

  // ── 出包 ──
  final zip = ZipEncoder().encode(archive) ?? <int>[];
  final id = doc['id'].toString();
  final out = outPath ?? 'build/packs/$id.smpack';
  final outFile = File(out);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(zip);

  stdout.writeln('');
  stdout.writeln('✅ 资源包已生成: $out（${(zip.length / 1024).toStringAsFixed(1)}KB）');
  stdout.writeln('   ${doc['displayName'] ?? id}：词书×$deckCount（$totalCards 卡）· 题目×$questionCount'
      '${syllabusRel != null && syllabusRel.isNotEmpty ? ' · 考纲' : ''}'
      '${litCount > 0 ? ' · 文献×$litCount' : ''}');
  stdout.writeln('   发给客户 → App 内点「导入我的专属资源包」即完成内置。');
}

/// 相对路径按配置文件所在目录解析；绝对路径直接用。
File? _resolve(String configPath, String p) {
  final f = File(p).existsSync() ? File(p) : File('${File(configPath).parent.path}/$p');
  return f.existsSync() ? f : null;
}

/// 词书卡数校验（与 App DeckImporter 同规则：ncpack=zip 内 pack.json；json=数组）。
int _countDeckCards(List<int> bytes, String name) {
  try {
    List<dynamic> cards;
    if (name.endsWith('.ncpack')) {
      final a = ZipDecoder().decodeBytes(bytes);
      final pack = a.files.firstWhere((f) => f.name == 'pack.json');
      final packJson = jsonDecode(utf8.decode(pack.content as List<int>));
      cards = [];
      for (final d in (packJson['decks'] as List? ?? [])) {
        cards.addAll((d['cards'] as List? ?? []));
      }
    } else {
      cards = jsonDecode(utf8.decode(bytes)) as List;
    }
    return cards.where((c) => (c['front'] ?? '').toString().isNotEmpty).length;
  } catch (_) {
    return -1; // 解析失败视为 0（质量门拦）
  }
}

/// 题库校验（与 App QuizImporter 同规则）。
int _validateQuestions(List<int> bytes, String name) {
  final list = jsonDecode(utf8.decode(bytes)) as List;
  var ok = 0;
  for (final e in list) {
    final m = e as Map<String, dynamic>;
    final id = (m['id'] ?? '').toString();
    final stem = (m['stem'] ?? '').toString();
    final options = (m['options'] as List?) ?? [];
    final answerIndex = (m['answerIndex'] as num?)?.toInt() ?? -1;
    if (id.isEmpty) {
      stderr.writeln('✗ 质量门不过：$name 有题缺 id');
      exit(1);
    }
    if (stem.isEmpty || options.length < 2 || answerIndex < 0) {
      stderr.writeln('✗ 质量门不过：题 $id（stem/options/answerIndex 非法）');
      exit(1);
    }
    ok++;
  }
  return ok;
}
