import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:three_cats_desk/core/db/database.dart';

/// 全量数据备份导出/导入（本地部署方向，2026-08-13）。
///
/// 本地专属版无云备份——换手机/重装/误删时，用户一年的 FSRS 复习进度和猫 intimacy
/// 都在本地。这里提供「一键导出成 JSON 备份文件 → 一键导入恢复」的闭环。
///
/// 设计要点：
/// - 导出 = 把各表 dump 成 JSON（含 schemaVersion 做前向兼容标记）。
/// - 导入 = 幂等恢复（insertOnConflictUpdate，重复导入不翻倍）。内置词书/题库靠
///   contentHash / id 判重，复习进度（cards.fsrsState/due）按 id 覆盖回写。
/// - 不导 SharedPreferences（猫 intimacy / 档案）——那些是设备级状态，由设置页单独导出。
///   本类只管 drift 业务数据（卡/词书/题/作答/笔记/文献/专注/活动）。
class BackupService {
  final AppDatabase db;
  BackupService(this.db);

  static const backupVersion = 1;

  /// 导出全量业务数据为 JSON 字符串。
  Future<String> exportToJson() async {
    final decks = await db.select(db.localDecks).get();
    final cards = await db.select(db.localCards).get();
    final focus = await db.select(db.focusSessions).get();
    final questions = await db.select(db.questions).get();
    final attempts = await db.select(db.attempts).get();
    final notes = await db.select(db.notes).get();
    final literature = await db.select(db.literature).get();
    final activity = await db.select(db.activityLog).get();
    final chats = await db.getAllChatMessages();
    final memories = await db.getAllMemories();
    final litChunks = await db.getAllChunks();

    return jsonEncode({
      'backupVersion': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'decks': decks.map((d) => {
            'id': d.id, 'name': d.name, 'kind': d.kind, 'accentHex': d.accentHex,
            'builtIn': d.builtIn, 'contentHash': d.contentHash, 'cardCount': d.cardCount,
            'createdAt': d.createdAt.toIso8601String(),
          }).toList(),
      'cards': cards.map((c) => {
            'id': c.id, 'deckId': c.deckId, 'noteId': c.noteId, 'type': c.type, 'front': c.front, 'back': c.back,
            'sourceApp': c.sourceApp, 'fsrsState': c.fsrsState,
            'due': c.due.toIso8601String(), 'state': c.state, 'synced': c.synced,
            'updatedAt': c.updatedAt.toIso8601String(),
          }).toList(),
      'focusSessions': focus.map((f) => {
            'id': f.id, 'startedAt': f.startedAt.toIso8601String(),
            'plannedMinutes': f.plannedMinutes, 'actualSeconds': f.actualSeconds,
            'completed': f.completed, 'sourceApp': f.sourceApp, 'synced': f.synced,
            'updatedAt': f.updatedAt.toIso8601String(),
          }).toList(),
      'questions': questions.map((q) => {
            'id': q.id, 'stem': q.stem, 'optionsJson': q.optionsJson,
            'answerIndex': q.answerIndex, 'explanation': q.explanation, 'subject': q.subject,
            'year': q.year, 'questionType': q.questionType, 'knowledgeTags': q.knowledgeTags,
            'source': q.source, 'sourceApp': q.sourceApp,
            'createdAt': q.createdAt.toIso8601String(),
          }).toList(),
      'attempts': attempts.map((a) => {
            'id': a.id, 'questionId': a.questionId, 'selectedIndex': a.selectedIndex,
            'isCorrect': a.isCorrect, 'answeredAt': a.answeredAt.toIso8601String(),
            'sourceApp': a.sourceApp, 'synced': a.synced,
          }).toList(),
      'notes': notes.map((n) => {
            'id': n.id, 'title': n.title, 'content': n.content, 'subject': n.subject,
            'sourceApp': n.sourceApp, 'synced': n.synced, 'archived': n.archived,
            'updatedAt': n.updatedAt.toIso8601String(), 'createdAt': n.createdAt.toIso8601String(),
          }).toList(),
      'literature': literature.map((l) => {
            'id': l.id, 'title': l.title, 'authors': l.authors, 'year': l.year, 'venue': l.venue,
            'doi': l.doi, 'url': l.url, 'abstractText': l.abstractText, 'note': l.note,
            'source': l.source, 'sourceApp': l.sourceApp, 'synced': l.synced, 'archived': l.archived,
            'updatedAt': l.updatedAt.toIso8601String(), 'createdAt': l.createdAt.toIso8601String(),
          }).toList(),
      'activityLog': activity.map((a) => {
            'day': a.day, 'openCount': a.openCount, 'reviewed': a.reviewed,
            'focusMinutes': a.focusMinutes, 'intimacy': a.intimacy,
            'firstOpenedAt': a.firstOpenedAt?.toIso8601String(),
            'lastOpenedAt': a.lastOpenedAt?.toIso8601String(),
          }).toList(),
      'chatMessages': chats.map((m) => {
            'id': m.id, 'sessionId': m.sessionId, 'role': m.role,
            'content': m.content, 'eventsJson': m.eventsJson,
            'createdAt': m.createdAt.toIso8601String(),
          }).toList(),
      'memoryEntries': memories.map((m) => {
            'id': m.id, 'slot': m.slot, 'text': m.body,
            'refs': m.refs, 'createdAt': m.createdAt.toIso8601String(),
          }).toList(),
    });
  }

  /// 从 JSON 备份恢复（幂等：insertOnConflictUpdate，重复导入不翻倍）。返回各表恢复行数。
  Future<Map<String, int>> importFromJson(String jsonStr) async {
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;
    final counts = <String, int>{};

    DateTime parse(Object? s) =>
        DateTime.tryParse(s?.toString() ?? '') ?? DateTime.now();

    final decks = (data['decks'] as List?) ?? [];
    for (final d in decks) {
      await db.into(db.localDecks).insertOnConflictUpdate(LocalDecksCompanion(
            id: Value(d['id'] as String), name: Value(d['name'] as String),
            kind: Value(d['kind'] as String? ?? 'vocab'),
            accentHex: Value((d['accentHex'] as num?)?.toInt() ?? 4099754),
            builtIn: Value(d['builtIn'] as bool? ?? true),
            contentHash: Value(d['contentHash'] as String? ?? ''),
            cardCount: Value((d['cardCount'] as num?)?.toInt() ?? 0),
            createdAt: Value(parse(d['createdAt'])),
          ));
    }
    counts['decks'] = decks.length;

    final cards = (data['cards'] as List?) ?? [];
    for (final c in cards) {
      await db.into(db.localCards).insertOnConflictUpdate(LocalCardsCompanion(
            id: Value(c['id'] as String), deckId: Value(c['deckId'] as String?),
            noteId: Value(c['noteId'] as String?),
            type: Value(c['type'] as String? ?? 'qa'), front: Value(c['front'] as String? ?? ''),
            back: Value(c['back'] as String?), sourceApp: Value(c['sourceApp'] as String? ?? 'niannian'),
            fsrsState: Value(c['fsrsState'] as String? ?? '{}'),
            due: Value(parse(c['due'])), state: Value((c['state'] as num?)?.toInt() ?? 0),
            synced: Value(c['synced'] as bool? ?? false), updatedAt: Value(parse(c['updatedAt'])),
          ));
    }
    counts['cards'] = cards.length;

    final focus = (data['focusSessions'] as List?) ?? [];
    for (final f in focus) {
      await db.into(db.focusSessions).insertOnConflictUpdate(FocusSessionsCompanion(
            id: Value(f['id'] as String), startedAt: Value(parse(f['startedAt'])),
            plannedMinutes: Value((f['plannedMinutes'] as num?)?.toInt() ?? 25),
            actualSeconds: Value((f['actualSeconds'] as num?)?.toInt() ?? 0),
            completed: Value(f['completed'] as bool? ?? false),
            sourceApp: Value(f['sourceApp'] as String? ?? 'nuannuan'),
            synced: Value(f['synced'] as bool? ?? false), updatedAt: Value(parse(f['updatedAt'])),
          ));
    }
    counts['focusSessions'] = focus.length;

    final questions = (data['questions'] as List?) ?? [];
    for (final q in questions) {
      await db.into(db.questions).insertOnConflictUpdate(QuestionsCompanion(
            id: Value(q['id'] as String), stem: Value(q['stem'] as String? ?? ''),
            optionsJson: Value(q['optionsJson'] as String? ?? '[]'),
            answerIndex: Value((q['answerIndex'] as num?)?.toInt() ?? 0),
            explanation: Value(q['explanation'] as String?),
            subject: Value(q['subject'] as String? ?? '政治'),
            year: Value((q['year'] as num?)?.toInt()),
            questionType: Value(q['questionType'] as String? ?? '单选'),
            knowledgeTags: Value(q['knowledgeTags'] as String? ?? '[]'),
            source: Value(q['source'] as String? ?? ''),
            sourceApp: Value(q['sourceApp'] as String? ?? 'wenwen'),
            createdAt: Value(parse(q['createdAt'])),
          ));
    }
    counts['questions'] = questions.length;

    final attempts = (data['attempts'] as List?) ?? [];
    for (final a in attempts) {
      await db.into(db.attempts).insertOnConflictUpdate(AttemptsCompanion(
            id: Value(a['id'] as String), questionId: Value(a['questionId'] as String? ?? ''),
            selectedIndex: Value((a['selectedIndex'] as num?)?.toInt() ?? 0),
            isCorrect: Value(a['isCorrect'] as bool? ?? false),
            answeredAt: Value(parse(a['answeredAt'])),
            sourceApp: Value(a['sourceApp'] as String? ?? 'wenwen'),
            synced: Value(a['synced'] as bool? ?? false),
          ));
    }
    counts['attempts'] = attempts.length;

    final notes = (data['notes'] as List?) ?? [];
    for (final n in notes) {
      await db.into(db.notes).insertOnConflictUpdate(NotesCompanion(
            id: Value(n['id'] as String), title: Value(n['title'] as String? ?? ''),
            content: Value(n['content'] as String? ?? ''),
            subject: Value(n['subject'] as String? ?? ''),
            sourceApp: Value(n['sourceApp'] as String? ?? 'zhizhi'),
            synced: Value(n['synced'] as bool? ?? false),
            archived: Value(n['archived'] as bool? ?? false),
            updatedAt: Value(parse(n['updatedAt'])), createdAt: Value(parse(n['createdAt'])),
          ));
    }
    counts['notes'] = notes.length;

    final literature = (data['literature'] as List?) ?? [];
    for (final l in literature) {
      await db.into(db.literature).insertOnConflictUpdate(LiteratureCompanion(
            id: Value(l['id'] as String), title: Value(l['title'] as String? ?? ''),
            authors: Value(l['authors'] as String? ?? ''), year: Value(l['year'] as String? ?? ''),
            venue: Value(l['venue'] as String? ?? ''), doi: Value(l['doi'] as String? ?? ''),
            url: Value(l['url'] as String? ?? ''),
            abstractText: Value(l['abstractText'] as String? ?? ''),
            note: Value(l['note'] as String? ?? ''),
            source: Value(l['source'] as String? ?? 'manual'),
            sourceApp: Value(l['sourceApp'] as String? ?? 'yuanyuan'),
            synced: Value(l['synced'] as bool? ?? false),
            archived: Value(l['archived'] as bool? ?? false),
            updatedAt: Value(parse(l['updatedAt'])), createdAt: Value(parse(l['createdAt'])),
          ));
    }
    counts['literature'] = literature.length;

    final activity = (data['activityLog'] as List?) ?? [];
    for (final a in activity) {
      await db.into(db.activityLog).insertOnConflictUpdate(ActivityLogCompanion(
            day: Value(a['day'] as String),
            openCount: Value((a['openCount'] as num?)?.toInt() ?? 0),
            reviewed: Value((a['reviewed'] as num?)?.toInt() ?? 0),
            focusMinutes: Value((a['focusMinutes'] as num?)?.toInt() ?? 0),
            intimacy: Value((a['intimacy'] as num?)?.toInt() ?? 0),
            firstOpenedAt: Value(a['firstOpenedAt'] == null ? null : parse(a['firstOpenedAt'])),
            lastOpenedAt: Value(a['lastOpenedAt'] == null ? null : parse(a['lastOpenedAt'])),
          ));
    }
    counts['activityLog'] = activity.length;

    final chats = (data['chatMessages'] as List?) ?? [];
    for (final m in chats) {
      await db.into(db.chatMessages).insertOnConflictUpdate(ChatMessagesCompanion(
        id: Value(m['id'] as String),
        sessionId: Value(m['sessionId'] as String),
        role: Value(m['role'] as String),
        content: Value(m['content'] as String),
        eventsJson: Value(m['eventsJson'] as String? ?? ''),
        createdAt: Value(parse(m['createdAt'])),
      ));
    }
    counts['chatMessages'] = chats.length;

    final mems = (data['memoryEntries'] as List?) ?? [];
    for (final m in mems) {
      await db.into(db.memoryEntries).insertOnConflictUpdate(MemoryEntriesCompanion(
        id: Value(m['id'] as String),
        slot: Value(m['slot'] as String),
        body: Value(m['text'] as String),
        refs: Value(m['refs'] as String? ?? ''),
        createdAt: Value(parse(m['createdAt'])),
      ));
    }
    counts['memoryEntries'] = mems.length;

    final lcs = (data['literatureChunks'] as List?) ?? [];
    for (final c in lcs) {
      await db.into(db.literatureChunks).insertOnConflictUpdate(LiteratureChunksCompanion(
        id: Value(c['id'] as String),
        literatureId: Value(c['literatureId'] as String),
        pageNo: Value((c['pageNo'] as num?)?.toInt() ?? 0),
        paraIndex: Value((c['paraIndex'] as num?)?.toInt() ?? 0),
        offsetStart: Value((c['offsetStart'] as num?)?.toInt() ?? -1),
        offsetEnd: Value((c['offsetEnd'] as num?)?.toInt() ?? -1),
        body: Value(c['body'] as String),
      ));
    }
    counts['literatureChunks'] = lcs.length;

    return counts;
  }
}
