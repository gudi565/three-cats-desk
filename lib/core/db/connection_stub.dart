import 'package:drift/drift.dart';

/// 平台连接接口（条件实现见 connection_io.dart / connection_web.dart）。
QueryExecutor openConnection() => throw UnsupportedError('no platform impl');
