import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Web：sqlite3 wasm + drift worker（IndexedDB 持久化）。
/// 资源：web/sqlite3.wasm + web/drift_worker.js（见 README/Phase0 §7）。
QueryExecutor openConnection() {
  return LazyDatabase(() async {
    final result = await WasmDatabase.open(
      databaseName: 'three_cats_desk',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );
    return result.resolvedExecutor;
  });
}
