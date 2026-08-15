import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/profile_notifier.dart';
import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';

/// 三猫书桌 · 站外壳侧栏（DeepTutor 形态，2026-08-15）。
///
/// 左栏结构（用户明确要求五猫在左栏）：
///   顶部品牌区：像素猫 + 「三猫书桌」+ 专属副标题（昵称/院校）
///   我的书桌区：首页 / 考研智能体 / 知识库 / 笔记本
///   五猫区：念念/暖暖/稳稳/知知/渊渊（按 profile 模块开关过滤）
///   底部：导入资源包 + 设置入口
///
/// 宽屏（≥840）固定左栏；窄屏收进 Drawer（同一内容，避免两套）。
class DeskShell extends ConsumerWidget {
  final int selectedIndex; // 当前选中的导航项
  final ValueChanged<int> onSelect; // 切换回调
  final Widget child; // 右侧主区内容

  const DeskShell({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
    required this.child,
  });

  /// 我的书桌区导航项（固定）。
  static const deskItems = [
    (Icons.home_outlined, '首页', 'home'),
    (Icons.auto_awesome_outlined, '考研智能体', 'agent'),
    (Icons.library_books_outlined, '知识库', 'knowledge'),
    (Icons.edit_note_outlined, '笔记本', 'notebook'),
  ];

  /// 五猫模块清单：(显示名, 副标题, 图标, 主色, 模块key)。
  static const catModules = [
    ('念念', '背书 · 翻卡复习', Icons.style_outlined, Color(0xFF3E8EAA), 'niannian'),
    ('暖暖', '专注 · 番茄钟', Icons.local_cafe_outlined, Color(0xFFE0A458), 'nuannuan'),
    ('稳稳', '做题 · 考研真题', Icons.checklist_outlined, Color(0xFF5B9E6F), 'wenwen'),
    ('知知', '笔记 · 笔记即卡片', Icons.edit_note_outlined, Color(0xFFB083C9), 'zhizhi'),
    ('渊渊', '文献 · 真实检索', Icons.menu_book_outlined, Color(0xFF8B7E6A), 'yuanyuan'),
  ];

  /// 全部导航项（desk 区 + 五猫区按开关过滤后）的扁平顺序，selectedIndex 对其。
  List<({IconData icon, String label, String key, Color? color})> _items(WidgetRef ref) {
    final content = ref.watch(contentProfileProvider);
    final desk = deskItems
        .map((d) => (icon: d.$1, label: d.$2, key: d.$3, color: null as Color?))
        .toList();
    final cats = catModules
        .where((m) => content.hasModule(m.$5))
        .map((m) => (icon: m.$3, label: m.$1, key: m.$5, color: m.$4 as Color?))
        .toList();
    return [...desk, ...cats];
  }

  /// 五猫区起始下标（desk 区长度）。
  static const catStartIndex = 4; // deskItems.length

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = _items(ref);
    final wide = MediaQuery.of(context).size.width >= 840;
    final sidebar = _Sidebar(
      items: items,
      selectedIndex: selectedIndex,
      onSelect: onSelect,
    );
    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            sidebar,
            const VerticalDivider(width: 1),
            Expanded(child: child),
          ],
        ),
      );
    }
    // 窄屏：AppBar + Drawer（同一侧栏内容）
    return Scaffold(
      appBar: AppBar(
        title: const Text('三猫书桌'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(child: SafeArea(child: sidebar)),
      body: child,
    );
  }
}

class _Sidebar extends ConsumerWidget {
  final List<({IconData icon, String label, String key, Color? color})> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _Sidebar({
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cat = ref.watch(catProvider);
    final profileName = ref.watch(contentProfileProvider).displayName;
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        width: 250,
        child: Column(
        children: [
          // 品牌区：像素猫 + 名称 + 专属包名
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFEAF4F7), Color(0xFFFDEEF1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Row(
              children: [
                PixelCat(mood: cat.mood, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('三猫书桌',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      Text(profileName,
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 导航项
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                _sectionLabel('我的书桌'),
                for (var i = 0; i < DeskShell.catStartIndex && i < items.length; i++)
                  _navTile(context, i, items[i]),
                if (items.length > DeskShell.catStartIndex) ...[
                  _sectionLabel('五猫'),
                  for (var i = DeskShell.catStartIndex; i < items.length; i++)
                    _navTile(context, i, items[i]),
                ],
              ],
            ),
          ),
          // 底部：亲密度
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('亲密度 ❤ ${cat.intimacy}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade500,
                letterSpacing: 1)),
      );

  Widget _navTile(BuildContext context, int index,
      ({IconData icon, String label, String key, Color? color}) item) {
    final selected = index == selectedIndex;
    final color = item.color ?? Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selected: selected,
        selectedTileColor: color.withValues(alpha: 0.12),
        leading: Icon(item.icon,
            size: 21, color: selected ? color : Colors.grey.shade700),
        title: Text(item.label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? color : null)),
        onTap: () {
          onSelect(index);
          // 窄屏 Drawer 里选中后收起
          if (Scaffold.of(context).hasDrawer &&
              Scaffold.of(context).isDrawerOpen) {
            Navigator.of(context).pop();
          }
        },
      ),
    );
  }
}
