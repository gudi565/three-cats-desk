import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/backup_service.dart';
import 'package:three_cats_desk/core/db/database.dart';

/// 对话记录持久化 + 备份闭环验证（P2-1）。
///
/// 钉死：消息写入/按会话读取正序/latestSessionId 续聊判定/
/// 备份导出→全新库导入→对话完整恢复（用户资产不丢）。
void main() {
  test('写入→按会话读取（时间正序）→ latestSessionId', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    // SQLite 时间戳精度到秒：显式 createdAt 保证排序确定性
    final base = DateTime(2026, 8, 15, 12, 0, 0);
    await db.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'm1', sessionId: 's1', role: 'user', content: '我错什么了',
        createdAt: Value(base)));
    await db.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'm2', sessionId: 's1', role: 'assistant', content: '你错了2道马原题',
        createdAt: Value(base.add(const Duration(seconds: 1)))));
    await db.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'm3', sessionId: 's2', role: 'user', content: '新会话',
        createdAt: Value(base.add(const Duration(seconds: 2)))));

    final s1 = await db.getChatMessages('s1');
    expect(s1.map((m) => m.id).toList(), ['m1', 'm2']); // 正序
    expect(s1.first.content, '我错什么了');
    expect(await db.latestSessionId(), 's2'); // 最近会话
  });

  test('备份闭环：导出→全新库→对话完整恢复', () async {
    final db1 = AppDatabase.forTesting(NativeDatabase.memory());
    await db1.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '帮我讲讲谢赫六法',
        eventsJson: const Value('[{"type":"AgentText"}]')));
    await db1.insertChatMessage(ChatMessagesCompanion.insert(
        id: 'm2', sessionId: 's1', role: 'assistant', content: '谢赫六法是...'));
    final json = await BackupService(db1).exportToJson();
    await db1.close();

    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db2.close());
    final counts = await BackupService(db2).importFromJson(json);
    expect(counts['chatMessages'], 2);

    final restored = await db2.getChatMessages('s1');
    expect(restored, hasLength(2));
    expect(restored.first.content, '帮我讲讲谢赫六法');
    expect(restored.first.eventsJson, contains('AgentText')); // 事件存档也恢复
    expect(restored.last.role, 'assistant');
    // JSON 严格合法（备份文件可被任何工具解析）
    expect(() => jsonDecode(json), returnsNormally);
  });
}
