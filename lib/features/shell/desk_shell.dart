import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/profile/content_profile.dart';
import '../../core/profile/profile_notifier.dart';
import '../cat/cat_provider.dart';
import '../cat/pixel_cat.dart';
import '../profile/onboarding_screen.dart';
import '../profile/pack_import_button.dart';

/// 三猫书桌 · 站外壳侧栏（DeepTutor 形态，2026-08-15）。
///
/// 左栏结构（用户明确要求五猫在左栏）：
///   顶部品牌区：像素猫 + 「三猫书桌」+ 专属副标题（包名）
///   我的书桌区：首页 / 考研智能体 / 知识库 / 笔记本（zhizhi 关）
///   五猫区：念念/暖暖/稳稳/知知/渊渊（按 profile 模块开关过滤）
///   底部：导入资源包 + 设置入口 + 亲密度（宽屏任何页都可达）
///
/// 宽屏（≥840）固定左栏；窄屏收进 Drawer（同一内容，避免两套）。
/// 导航按 key（非位置索引）：装包增删模块不错位。
class DeskShell extends ConsumerWidget {
  /// 导航 key 列表（desk 区固定前缀 + 五猫按开关过滤），顺序 = 侧栏顺序。
  final List<String> items;
  final String selectedKey; // 当前选中 key
  final ValueChanged<String> onSelectKey;
  final Widget child; // 右侧主区内容

  const DeskShell({
    super.key,
    required this.items,
    required this.selectedKey,
    required this.onSelectKey,
    required this.child,
  });

  /// 我的书桌区（固定 key 前缀）。侧栏与 main 的 _pagesFor 共用顺序约定。
  static const deskKeys = ['home', 'agent', 'knowledge', 'notebook'];

  static const _deskMeta = {
    'home': (Icons.home_outlined, '首页'),
    'agent': (Icons.auto_awesome_outlined, '考研智能体'),
    'knowledge': (Icons.library_books_outlined, '知识库'),
    'notebook': (Icons.edit_note_outlined, '笔记本'),
  };

  /// 五猫模块清单：(显示名, 副标题, 图标, 主色, 模块key)。
  static const catModules = [
    ('念念', '背书 · 翻卡复习', Icons.style_outlined, Color(0xFF3E8EAA), 'niannian'),
    ('暖暖', '专注 · 番茄钟', Icons.local_cafe_outlined, Color(0xFFE0A458), 'nuannuan'),
    ('稳稳', '做题 · 考研真题', Icons.checklist_outlined, Color(0xFF5B9E6F), 'wenwen'),
    ('知知', '笔记 · 笔记即卡片', Icons.edit_note_outlined, Color(0xFFB083C9), 'zhizhi'),
    ('渊渊', '文献 · 真实检索', Icons.menu_book_outlined, Color(0xFF8B7E6A), 'yuanyuan'),
  ];

  static _metaOf(String key) {
    if (_deskMeta.containsKey(key)) return _deskMeta[key]!;
    final m = catModules.firstWhere((m) => m.$5 == key,
        orElse: () => catModules.first);
    return (m.$3, m.$1);
  }

  static Color? _colorOf(String key) {
    for (final m in catModules) {
      if (m.$5 == key) return m.$4;
    }
    return null;
  }

  /// 五猫区起始 key（desk 区之后第一个）。
  static bool isCatKey(String key) => catModules.any((m) => m.$5 == key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.of(context).size.width >= 840;
    final sidebar = _Sidebar(
      items: items,
      selectedKey: selectedKey,
      onSelectKey: onSelectKey,
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
  final List<String> items;
  final String selectedKey;
  final ValueChanged<String> onSelectKey;

  const _Sidebar({
    required this.items,
    required this.selectedKey,
    required this.onSelectKey,
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
                            style: TextStyle(
                                fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(profileName,
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // 导航项（按 key，desk 区与五猫区自动分组——以猫 key 为界）
            Expanded(
              child: Builder(builder: (context) {
                final catKeys = items.where(DeskShell.isCatKey).toList();
                final deskKeys = items.where((k) => !DeskShell.isCatKey(k)).toList();
                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    _sectionLabel('我的书桌'),
                    for (final k in deskKeys) _navTile(context, k),
                    if (catKeys.isNotEmpty) ...[
                      _sectionLabel('五猫'),
                      for (final k in catKeys) _navTile(context, k),
                    ],
                  ],
                );
              }),
            ),
            const Divider(height: 1),
            // 底部操作区：导入 + 设置 + 亲密度（宽屏任何页面都可达——审查回归⑥修复）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
              child: Column(
                children: [
                  Row(children: [
                    const Expanded(child: PackImportButton(compact: false)),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.person_outline),
                      tooltip: '我的资料',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const OnboardingScreen()),
                      ),
                    ),
                  ]),
                  Text('亲密度 ❤ ${cat.intimacy}',
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade600)),
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

  Widget _navTile(BuildContext context, String key) {
    final selected = key == selectedKey;
    final (icon, label) = DeskShell._metaOf(key);
    final color = DeskShell._colorOf(key) ??
        Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: ListTile(
        dense: true,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        selected: selected,
        selectedTileColor: color.withValues(alpha: 0.12),
        leading: Icon(icon,
            size: 21, color: selected ? color : Colors.grey.shade700),
        title: Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? color : null)),
        onTap: () {
          onSelectKey(key);
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
