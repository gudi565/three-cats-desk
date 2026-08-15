import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/database.dart';
import '../../core/profile/profile_notifier.dart';
import '../../core/providers.dart';
import '../profile/pack_import_button.dart';

/// 知识库：已装内容包的全貌（词书/题库/考纲/文献统计）。
///
/// 站外壳阶段 = 只读总览（数据真实来自 drift）。L2 接 RAG 检索后，
/// 这里是"智能体读得懂的资料"的可视化。
class KnowledgeScreen extends ConsumerWidget {
  const KnowledgeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(appDatabaseProvider);
    // watch profile：装包后 contentProfileProvider 变化 → key 变 → 重查
    // （修复审查回归⑦：导入成功后本屏立即刷新，不再显示旧空态）。
    final profileRev = ref.watch(contentProfileProvider).id;
    return Scaffold(
      body: FutureBuilder<List<_KbRow>>(
        key: ValueKey('kb-$profileRev'),
        future: _load(db),
        builder: (context, snap) {
          final rows = snap.data ?? const <_KbRow>[];
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Row(children: [
                Icon(Icons.library_books_outlined, color: Color(0xFF3E8EAA)),
                SizedBox(width: 8),
                Text('知识库',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 6),
              Text('已内置的资料——五猫和智能体都从这里取内容。',
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              const SizedBox(height: 16),
              if (snap.connectionState != ConnectionState.done)
                const Center(child: CircularProgressIndicator())
              else if (rows.isEmpty)
                _empty(context)
              else
                ...rows.map((r) => Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: r.color,
                          child: Icon(r.icon, color: Colors.white, size: 20),
                        ),
                        title: Text(r.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(r.kind),
                        trailing: Text(r.count,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 15)),
                      ),
                    )),
              const SizedBox(height: 16),
              const Center(child: PackImportButton()),
            ],
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context) => Card(
        color: const Color(0xFFFFF8EC),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Text('📦', style: TextStyle(fontSize: 40)),
              const SizedBox(height: 8),
              const Text('还没有内置资料',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('导入你的专属资源包（.smpack），词书、题库、考纲、文献会出现在这里。',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            ],
          ),
        ),
      );

  Future<List<_KbRow>> _load(AppDatabase db) async {
    final decks = await db.getAllDecks();
    final qCount = await db.countQuestions();
    final notes = await db.getNotes();
    final lit = await db.getLiteratureList();
    final rows = <_KbRow>[
      for (final d in decks)
        _KbRow(d.name, '词书 · ${d.cardCount} 张卡', '${d.cardCount}',
            Icons.style_outlined, const Color(0xFF3E8EAA)),
      if (qCount > 0)
        _KbRow('题库', '稳稳 · 客观题', '$qCount', Icons.checklist_outlined,
            const Color(0xFF5B9E6F)),
      for (final n in notes)
        _KbRow(n.title.isEmpty ? '（无标题笔记）' : n.title, '笔记/考纲', '✓',
            Icons.edit_note_outlined, const Color(0xFFB083C9)),
      if (lit.isNotEmpty)
        _KbRow('文献库', '渊渊 · 已收录', '${lit.length}', Icons.menu_book_outlined,
            const Color(0xFF8B7E6A)),
    ];
    return rows;
  }
}

class _KbRow {
  final String name;
  final String kind;
  final String count;
  final IconData icon;
  final Color color;
  _KbRow(this.name, this.kind, this.count, this.icon, this.color);
}
