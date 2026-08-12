import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
import 'core/supabase_client.dart';
import 'features/cat/cat_provider.dart';
import 'features/cat/pixel_cat.dart';
import 'features/niannian/login_screen.dart';
import 'features/niannian/review_screen.dart';
import 'features/nuannuan/focus_provider.dart';
import 'features/nuannuan/focus_screen.dart';
import 'features/wenwen/quiz_screen.dart';
import 'features/zhizhi/notes_screen.dart';
import 'features/yuanyuan/yuanyuan_screen.dart';

/// 内置词书（从 legacy 念念/MemoryCat 拷贝，Phase0 §5）。启动幂等导入。
const _bundledDecks = [
  'assets/decks/熟词僻义.ncpack',
  'assets/decks/考研英语核心词组.ncpack',
  'assets/decks/english-kaoyan-hifi.json',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Supabase 初始化（失败降级 local-first，不阻塞启动）
  await SupabaseConfig.initialize();
  runApp(const ProviderScope(child: BootstrapApp()));
}

/// Bootstrap：先导入词书进 drift，再进 App。导入幂等（contentHash 判重）。
class BootstrapApp extends ConsumerStatefulWidget {
  const BootstrapApp({super.key});

  @override
  ConsumerState<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends ConsumerState<BootstrapApp> {
  late final Future<void> _ready = _bootstrap();

  Future<void> _bootstrap() async {
    final importer = ref.read(deckImporterProvider);
    for (final path in _bundledDecks) {
      try {
        await importer.importFromAsset(path);
      } catch (e) {
        debugPrint('[bootstrap] 导入 $path 失败：$e'); // 单本失败不阻塞其它
      }
    }
    // 登录态恢复后重试未同步卡（PUSH）
    if (SupabaseConfig.isLoggedIn) {
      await ref.read(cloudSyncProvider).pushAllUnsynced();
    }
    // 稳稳题库（幂等按 id）——assets/questions/*.json
    try {
      await ref.read(quizImporterProvider).importFromAsset('assets/questions/sample-quiz.json');
    } catch (e) {
      debugPrint('[bootstrap] 题库导入失败：$e');
    }
    // 雷2 埋点：登录态确立后，猫 key 重绑到该 userId（防同设备多账号串猫），
    // 并标今日打开（留存度量唯一云端信号）+ 顺手带上 intimacy 快照（防资产归零+归因）。
    if (SupabaseConfig.isLoggedIn) {
      final cat = ref.read(catProvider.notifier);
      await cat.bindUser(SupabaseConfig.currentUser!.id);
      await ref.read(cloudSyncProvider).markActivity(intimacy: ref.read(catProvider).intimacy);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const MaterialApp(
            home: Scaffold(body: Center(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Text('🐱', style: TextStyle(fontSize: 56)),
                SizedBox(height: 16),
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('三猫书桌 · 加载词书中'),
              ]),
            )),
          );
        }
        return const SanmaoApp();
      },
    );
  }
}

class SanmaoApp extends ConsumerWidget {
  const SanmaoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      ],
    );
    return MaterialApp.router(
      title: '三猫书桌',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF3E8EAA)),
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}

/// 主页：1 App 五模块骨架。Phase0 只「念念」可用，其余留占位（后面阶段填）。
/// 顶部猫横条（Phase 1a）：首屏就看见猫，强化「为猫打开」hook。
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  static const _modules = [
    ('念念', '背书 · 翻卡复习', Icons.style_outlined, Color(0xFF3E8EAA), true),
    ('暖暖', '专注 · 番茄钟', Icons.local_cafe_outlined, Color(0xFFE0A458), true),
    ('稳稳', '做题 · 考研真题', Icons.checklist_outlined, Color(0xFF5B9E6F), true),
    ('知知', '笔记 · 笔记即卡片', Icons.edit_note_outlined, Color(0xFFB083C9), true),
    ('渊渊', '文献 · 真实检索', Icons.menu_book_outlined, Color(0xFF8B7E6A), true),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cat = ref.watch(catProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('三猫书桌 · 考研'),
        actions: [
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CatGreeting(mood: cat.mood, intimacy: cat.intimacy, today: cat.todayReviewed),
          const SizedBox(height: 12),
          const _TodayOverview(), // 跨模块今日总览（暖暖仪表盘底座）
          const SizedBox(height: 12),
          for (final m in _modules)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: m.$4,
                  child: Icon(m.$3, color: Colors.white),
                ),
                title: Text(m.$1),
                subtitle: Text(m.$2),
                trailing: m.$5
                    ? const Icon(Icons.chevron_right)
                    : const Chip(label: Text('待开'), visualDensity: VisualDensity.compact),
                enabled: m.$5,
                onTap: !m.$5
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => m.$1 == '暖暖'
                                ? const FocusScreen()
                                : m.$1 == '稳稳'
                                    ? const WenwenHomeScreen()
                                    : m.$1 == '知知'
                                        ? const ZhizhiHomeScreen()
                                        : m.$1 == '渊渊'
                                            ? const YuanyuanHomeScreen()
                                            : const DeckListScreen(),
                          ),
                        ),
              ),
            ),
          const SizedBox(height: 16),
          const Center(
            child: Text('Phase2 · 念念翻卡 + 暖暖专注 + 猫养成',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

/// 首屏猫问候横条：像素猫 + 心情 + 今日复习数。
/// 「今天还没复习」时引导用户进念念——这是次日留存的关键推力。
class _CatGreeting extends StatelessWidget {
  final CatMood mood;
  final int intimacy;
  final int today;
  const _CatGreeting({required this.mood, required this.intimacy, required this.today});

  @override
  Widget build(BuildContext context) {
    final hasReviewedToday = today > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFEAF4F7), Color(0xFFFDEEF1)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          PixelCat(mood: mood, size: 48),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasReviewedToday
                      ? '今天复习了 $today 张，猫咪很满足～'
                      : '猫咪在等你今天来复习哦！',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '亲密度 ❤ $intimacy · ${mood.label}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 跨模块今日总览（暖暖仪表盘底座）：今日复习张数 + 今日专注分钟。
/// 这是"5 模块拧成一股绳"的第一个可见证据——一个屏看到念念和暖暖的今日进度。
class _TodayOverview extends ConsumerWidget {
  const _TodayOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final focus = ref.watch(todayFocusProvider);
    final reviewed = ref.watch(catProvider).todayReviewed;
    final focusMinutes = focus.value?.minutes ?? 0;
    final focusSessions = focus.value?.sessions ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _Stat(icon: '📚', label: '今日复习', value: '$reviewed 张'),
          _divider(),
          _Stat(icon: '⏱️', label: '今日专注', value: '$focusMinutes 分钟'),
          _divider(),
          _Stat(icon: '🐱', label: '专注完成', value: '$focusSessions 次'),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 30, color: Colors.grey.shade300);

  Widget _Stat({required String icon, required String label, required String value}) {
    return Column(
      children: [
        Text(icon, style: const TextStyle(fontSize: 18)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
      ],
    );
  }
}
