import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import 'notes_provider.dart';

/// 知知笔记首页：笔记列表 → 新建/编辑。
class ZhizhiHomeScreen extends ConsumerWidget {
  const ZhizhiHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(noteListProvider);
    final cat = ref.watch(catProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('知知 · 笔记'),
        actions: [Padding(padding: const EdgeInsets.only(right: 12),
            child: Center(child: PixelCat(mood: cat.mood, size: 36)))],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFFB083C9),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const NoteEditorScreen(note: null)),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建笔记'),
      ),
      body: notes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => list.isEmpty
            ? const Center(child: Padding(padding: EdgeInsets.all(40),
                child: Text('还没有笔记\n点右下角新建，写完一键变复习卡', textAlign: TextAlign.center)))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final n = list[i];
                  return Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Color(0xFFB083C9),
                        child: Icon(Icons.edit_note, color: Colors.white),
                      ),
                      title: Text(n.title.isEmpty ? '（无标题）' : n.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(n.content.isEmpty ? '' : n.content,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => NoteEditorScreen(note: n)),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

/// 笔记编辑器：标题 + Markdown 正文 + 「转复习卡」。
class NoteEditorScreen extends ConsumerStatefulWidget {
  final dynamic note; // Note?（null=新建）
  const NoteEditorScreen({super.key, required this.note});

  @override
  ConsumerState<NoteEditorScreen> createState() => _NoteEditorScreenState();
}

class _NoteEditorScreenState extends ConsumerState<NoteEditorScreen> {
  late final TextEditingController _title;
  late final TextEditingController _content;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.note?.title ?? '');
    _content = TextEditingController(text: widget.note?.content ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editor = ref.read(noteEditorProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.note == null ? '新建笔记' : '编辑笔记'),
        actions: [
          // 笔记即卡片：一键转念念复习卡
          IconButton(
            icon: const Icon(Icons.style_outlined),
            tooltip: '转为复习卡（进念念）',
            onPressed: () => _toCard(context),
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: '保存',
            onPressed: () => _save(context, editor),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(
                hintText: '标题', border: InputBorder.none,
              ),
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            Expanded(
              child: TextField(
                controller: _content,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: '用 Markdown 写笔记…\n\n写完点右上角 🃏 一键变成念念复习卡',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 16, height: 1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save(BuildContext context, dynamic editor) async {
    // 新建则先 newNote，再 save
    final notifier = ref.read(noteEditorProvider.notifier);
    if (widget.note != null) notifier.open(widget.note);
    if (ref.read(noteEditorProvider) == null) notifier.newNote();
    await notifier.save(title: _title.text.trim(), content: _content.text.trim());
    ref.read(noteRevisionProvider.notifier).state++;
    if (mounted) {
      setState(() => _saved = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
    }
  }

  Future<void> _toCard(BuildContext context) async {
    final content = _content.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('先写点内容再转卡')));
      return;
    }
    // 取首行作 front，其余作 back（笔记即卡片的最小实现）。
    final lines = content.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final front = lines.first.replaceFirst(RegExp(r'^#+\s*'), '');
    final back = lines.length > 1 ? lines.sublist(1).join('\n') : '（见笔记全文）';
    final notifier = ref.read(noteEditorProvider.notifier);
    if (ref.read(noteEditorProvider) == null) notifier.newNote();
    final noteId = ref.read(noteEditorProvider)?.id ?? '';
    await noteToCard(ref, noteId: noteId, front: front, back: back);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🐱 已转为复习卡，进念念「跨猫卡箱」')),
      );
    }
  }
}
