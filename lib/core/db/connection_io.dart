import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 原生（安卓/iOS/macOS）：SQLite 落盘到应用文档目录，后台 isolate。
QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'three_cats_desk.sqlite'));
    return NativeDatabase.createInBackground(file);
  });
}
