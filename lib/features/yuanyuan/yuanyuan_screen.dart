import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import 'literature_provider.dart';
import 'literature_search.dart';

/// 渊渊文献首页：文献库 + 检索 + 「问你的文献」留口。
class YuanyuanHomeScreen extends ConsumerWidget {
  const YuanyuanHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(literatureListProvider);
    final cat = ref.watch(catProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('渊渊 · 文献'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '检索文献（CrossRef 真实数据）',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LiteratureSearchScreen()),
            ),
          ),
          Padding(padding: const EdgeInsets.only(right: 8),
              child: Center(child: PixelCat(mood: cat.mood, size: 34))),
        ],
      ),
      body: list.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (items) => Column(
          children: [
            // 「问你的文献」诚实留口（后端 RAG 未部署）
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF0EBF5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(children: [
                Text('💬', style: TextStyle(fontSize: 18)),
                SizedBox(width: 10),
                Expanded(child: Text('「问你的文献」（AI 问答）需部署云端 RAG，即将上线。先用检索 + 摘录转卡。',
                    style: TextStyle(fontSize: 12, color: Color(0xFF5B4A6B)))),
              ]),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Padding(padding: EdgeInsets.all(40),
                      child: Text('文献库是空的\n点右上角 🔍 检索真实文献加入', textAlign: TextAlign.center)))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: items.length,
                      itemBuilder: (context, i) => _LiteratureTile(lit: items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LiteratureTile extends ConsumerWidget {
  final dynamic lit; // LiteratureData
  const _LiteratureTile({required this.lit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Color(0xFF8B7E6A),
          child: Icon(Icons.menu_book_outlined, color: Colors.white),
        ),
        title: Text(lit.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [lit.authors, lit.year, lit.venue].where((s) => (s as String).isNotEmpty).join(' · '),
          maxLines: 1, overflow: TextOverflow.ellipsis,
        ),
        trailing: IconButton(
          icon: const Icon(Icons.style_outlined, color: Color(0xFF3E8EAA)),
          tooltip: '摘录转复习卡（进念念）',
          onPressed: () => _toCard(context, ref),
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => LiteratureDetailScreen(lit: lit)),
        ),
      ),
    );
  }

  Future<void> _toCard(BuildContext context, WidgetRef ref) async {
    final excerpt = lit.abstractText.isNotEmpty ? lit.abstractText : (lit.note.isNotEmpty ? lit.note : lit.venue);
    await literatureToCard(ref, literatureId: lit.id, title: lit.title, excerpt: excerpt);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('🐱 已转为复习卡，进念念「跨猫卡箱」')),
      );
    }
  }
}

/// 文献详情：元数据 + 摘要 + 我的批注 + 转卡。
class LiteratureDetailScreen extends ConsumerWidget {
  final dynamic lit; // LiteratureData
  const LiteratureDetailScreen({super.key, required this.lit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('文献详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(lit.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text([lit.authors, lit.year, lit.venue].where((s) => (s as String).isNotEmpty).join(' · '),
              style: TextStyle(color: Colors.grey.shade700)),
          if ((lit.doi as String).isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4),
                child: Text('DOI: ${lit.doi}', style: TextStyle(fontSize: 12, color: Colors.grey.shade500))),
          const Divider(height: 32),
          if ((lit.abstractText as String).isNotEmpty) ...[
            const Text('摘要', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(lit.abstractText, style: const TextStyle(height: 1.6)),
            const SizedBox(height: 16),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF8B7E6F)),
              icon: const Icon(Icons.style_outlined),
              label: const Text('摘要转复习卡（进念念）'),
              onPressed: () async {
                await literatureToCard(ref,
                    literatureId: lit.id, title: lit.title,
                    excerpt: (lit.abstractText as String).isNotEmpty ? lit.abstractText : lit.venue);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('🐱 已转为复习卡')),
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 检索屏：CrossRef 真实检索 → 加入文献库。
class LiteratureSearchScreen extends ConsumerWidget {
  const LiteratureSearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(literatureSearchProvider);
    final notifier = ref.read(literatureSearchProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('检索文献 · CrossRef')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: '输入关键词，如 "deep learning" / "注意力机制"',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onSubmitted: notifier.search,
            ),
          ),
          if (search.loading) const LinearProgressIndicator(),
          Expanded(
            child: search.hits.isEmpty && !search.loading
                ? Center(child: Text(search.query.isEmpty ? '输入关键词检索真实学术文献' : '无结果',
                    style: TextStyle(color: Colors.grey.shade600)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: search.hits.length,
                    itemBuilder: (context, i) => _HitTile(hit: search.hits[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _HitTile extends ConsumerWidget {
  final CrossRefHit hit;
  const _HitTile({required this.hit});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: ListTile(
        title: Text(hit.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text([hit.authors, hit.year, hit.venue].where((s) => s.isNotEmpty).join(' · '),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: IconButton(
          icon: const Icon(Icons.add_circle_outline, color: Color(0xFF8B7E6F)),
          tooltip: '加入文献库',
          onPressed: () async {
            final added = await addHitToLibrary(ref, hit);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(added ? '已加入文献库' : '文献库已有这篇（DOI 去重）'),
              ));
            }
          },
        ),
      ),
    );
  }
}
