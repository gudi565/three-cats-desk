import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:three_cats_desk/core/db/database.dart';
import 'package:drift/drift.dart' show Value;

/// 题库导入器：从 assets 加载题 → 写入 drift questions 表（幂等按 id）。
///
/// JSON 格式（sample-quiz.json，一个数组）：
///   [{"id":"zz-001","subject":"政治","stem":"...","options":["..","..","..",".."],
///     "answerIndex":0,"explanation":"...","source":"政治·马原"}, ...]
/// 铁律：AI 不出题（稳稳只做真实/人产题），这里只导入内容侧产好的 JSON。
class QuizImporter {
  final AppDatabase db;
  QuizImporter(this.db);

  /// 从 asset 导入题库。返回导入题数；重复 id 幂等更新。
  Future<int> importFromAsset(String assetPath) async {
    final bytes = await rootBundle.load(assetPath);
    return importFromBytes(bytes.buffer.asUint8List());
  }

  /// 从字节流导入（.smpack 运行时安装 / CLI 生成器校验共用路径）。幂等按 id。
  Future<int> importFromBytes(List<int> data) async {
    final list = jsonDecode(utf8.decode(data)) as List;
    var n = 0;
    final companions = <QuestionsCompanion>[];
    for (final e in list) {
      final m = e as Map<String, dynamic>;
      final id = (m['id'] ?? '').toString();
      final stem = (m['stem'] ?? '').toString();
      final options = (m['options'] as List?)?.map((o) => o.toString()).toList() ?? [];
      final answerIndex = (m['answerIndex'] as num?)?.toInt() ?? -1;
      if (id.isEmpty || stem.isEmpty || options.length < 2 || answerIndex < 0) continue;
      final tags = (m['knowledgeTags'] as List?)
              ?.map((t) => t.toString()).toList() ??
          const <String>[];
      companions.add(QuestionsCompanion(
        id: Value(id),
        stem: Value(stem),
        optionsJson: Value(jsonEncode(options)),
        answerIndex: Value(answerIndex),
        explanation: Value((m['explanation'] ?? '').toString()),
        subject: Value((m['subject'] ?? '政治').toString()),
        year: Value((m['year'] as num?)?.toInt()),
        questionType: Value((m['questionType'] ?? '单选').toString()),
        knowledgeTags: Value(jsonEncode(tags)),
        source: Value((m['source'] ?? '').toString()),
      ));
      n++;
    }
    await db.insertQuestions(companions);
    return n;
  }
}
