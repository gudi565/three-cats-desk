import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:three_cats_desk/core/cross_app_cards.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:uuid/uuid.dart';

import '../../core/deck_providers.dart';

/// 知知笔记模块。
///
/// 签名能力「笔记即卡片」：笔记一键转念念 FSRS 复习卡（type=qa, source_app=zhizhi），
/// 进念念"跨猫卡箱"复习队列——笔记→背书，这是知知对 Notability/GoodNotes 的差异化。

/// 笔记列表（新更新在前）。
final noteListProvider = FutureProvider<List<Note>>((ref) async {
  ref.watch(noteRevisionProvider);
  return ref.watch(appDatabaseProvider).getNotes();
});

/// 修订号：增删改后自增，触发列表/仪表盘刷新。
final noteRevisionProvider = StateProvider<int>((ref) => 0);

/// 笔记编辑/新建。
class NoteNotifier extends StateNotifier<Note?> {
  final AppDatabase db;
  final Future<void> Function(Note)? onPersisted;
  static const _uuid = Uuid();

  NoteNotifier(this.db, {this.onPersisted}) : super(null);

  /// 新建一条空笔记。
  void newNote() {
    state = Note(
      id: _uuid.v4(), title: '', content: '', subject: '',
      sourceApp: 'zhizhi', synced: false, archived: false,
      updatedAt: DateTime.now(), createdAt: DateTime.now(),
    );
  }

  /// 打开已有笔记编辑。
  void open(Note n) => state = n;

  /// 保存（本地 + 异步上云）。
  Future<void> save({required String title, required String content, String subject = ''}) async {
    final cur = state ?? Note(
      id: _uuid.v4(), title: '', content: '', subject: '',
      sourceApp: 'zhizhi', synced: false, archived: false,
      updatedAt: DateTime.now(), createdAt: DateTime.now(),
    );
    final updated = Note(
      id: cur.id, title: title, content: content, subject: subject,
      sourceApp: 'zhizhi', synced: false, archived: cur.archived,
      updatedAt: DateTime.now(), createdAt: cur.createdAt,
    );
    await db.upsertNote(updated.toCompanion(true));
    state = updated;
    final cb = onPersisted;
    if (cb != null) cb(updated);
  }

  void close() => state = null;
}

final noteEditorProvider = StateNotifierProvider.autoDispose<NoteNotifier, Note?>((ref) {
  return NoteNotifier(
    ref.watch(appDatabaseProvider),
    onPersisted: (n) => ref.read(cloudSyncProvider).pushNote(n),
  );
});

/// 笔记→念念复习卡（笔记即卡片）。
///
/// 写 cards(type=qa, source_app=zhizhi, deck=跨猫卡箱) → 念念复习队列。
/// 复用跨猫卡箱 helper（确保 deckId 非 null）。ref 放宽为 dynamic（Ref/WidgetRef 皆可）。
Future<void> noteToCard(dynamic ref, {required String noteId, required String front, required String back}) async {
  await CrossAppCards.add(ref, front: front, back: back, sourceApp: 'zhizhi', type: 'qa', sourceRef: noteId);
  ref.read(noteRevisionProvider.notifier).state++;
}
