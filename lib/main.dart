import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/app_mode.dart';
import 'core/profile/content_profile.dart';
import 'core/profile/profile_notifier.dart';
import 'core/providers.dart';
import 'core/supabase_client.dart';
import 'features/cat/cat_provider.dart';
import 'features/cat/pixel_cat.dart';
import 'features/niannian/login_screen.dart';
import 'features/niannian/review_screen.dart';
import 'features/nuannuan/focus_provider.dart';
import 'features/nuannuan/focus_screen.dart';
import 'features/profile/onboarding_screen.dart';
import 'features/profile/pack_import_button.dart';
import 'features/profile/user_profile.dart';
import 'features/shell/agent_screen.dart';
import 'features/shell/desk_shell.dart';
import 'features/shell/knowledge_screen.dart';
import 'features/wenwen/quiz_screen.dart';
import 'features/zhizhi/notes_screen.dart';
import 'features/yuanyuan/yuanyuan_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Supabase 初始化（仅 cloud 模式；local 本地专属版跳过，彻底无云端依赖）。
  // 失败降级 local-first，不阻塞启动。
  if (AppMode.isCloud) {
    await SupabaseConfig.initialize();
  }
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
    // 内容包驱动导入（按人定制的引擎）：探测客户 profile → 导入其词书/题库/考纲，
    // 找不到客户包 → 回落通用版（公共课词书+示例题库）。幂等，单失败不阻塞。
    try {
      await ref.read(contentProfileProvider.notifier).loadAndImport();
    } catch (e) {
      debugPrint('[bootstrap] profile 导入失败：$e');
    }
    // 登录态恢复后重试未同步卡（PUSH）
    if (SupabaseConfig.isLoggedIn) {
      await ref.read(cloudSyncProvider).pushAllUnsynced();
    }
    // 雷2 埋点：登录态确立后，猫 key 重绑到该 userId（防同设备多账号串猫），
    // 并标今日打开（留存度量唯一云端信号）+ 顺手带上 intimacy 快照（防资产归零+归因）。
    if (SupabaseConfig.isLoggedIn) {
      final cat = ref.read(catProvider.notifier);
      await cat.bindUser(SupabaseConfig.currentUser!.id);
      await ref.read(cloudSyncProvider).markActivity(intimacy: ref.read(catProvider).intimacy);
    }
    // 本地留存度量（本地专属版观测仪器，无云端时的唯一留存信号）：
    // 标今日打开 + intimacy 快照。local-first：写本地 drift，不依赖网络。
    try {
      final now = DateTime.now();
      final day = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      await ref.read(appDatabaseProvider).recordAppOpen(day,
          intimacy: ref.read(catProvider).intimacy);
    } catch (e) {
      debugPrint('[bootstrap] recordAppOpen 失败：$e'); // 度量失败不阻塞启动
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
    final profile = ref.watch(userProfileProvider);
    // 本地专属版：未完成初始化向导 → 先进 Onboarding（无账号，填昵称/院校/日期）。
    // 完成后进主页。设置页可改。
    final router = GoRouter(
      initialLocation: profile.setupDone ? '/' : '/onboarding',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
        GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
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

/// 主页：站外壳（DeepTutor 形态，2026-08-15）。
/// 左栏 = 首页/考研智能体/知识库/笔记本 + 五猫五个项目；右侧为主区。
/// 宽屏固定侧栏，窄屏 Drawer。
///
/// 导航用 key（非位置索引）：装包增删模块后选中项跟随 key 不错位；
/// 笔记本入口受 zhizhi 开关约束（按人定制 gating 不被绕过）。
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String _selectedKey = 'home';

  List<({String key, Widget page})> _pagesFor(ContentProfile content) {
    final pages = <({String key, Widget page})>[
      (key: 'home', page: _HomeContent(onOpenModule: (k) => setState(() => _selectedKey = k))),
      (key: 'agent', page: const AgentScreen()),
      (key: 'knowledge', page: const KnowledgeScreen()),
      // 笔记本 = 知知的入口，受 zhizhi 模块开关约束（客户关掉知知则不显示）。
      if (content.hasModule('zhizhi')) (key: 'notebook', page: const ZhizhiHomeScreen()),
    ];
    for (final m in DeskShell.catModules) {
      if (content.hasModule(m.$5)) {
        pages.add((key: m.$5, page: _catPage(m.$5)));
      }
    }
    return pages;
  }

  Widget _catPage(String key) {
    switch (key) {
      case 'nuannuan':
        // keepAlive：壳内嵌页面切走不销毁——专注计时中切页不丢会话。
        return const _KeepAlive(child: FocusScreen());
      case 'wenwen':
        return const _KeepAlive(child: WenwenHomeScreen());
      case 'zhizhi':
        return const _KeepAlive(child: ZhizhiHomeScreen());
      case 'yuanyuan':
        return const _KeepAlive(child: YuanyuanHomeScreen());
      default:
        return const _KeepAlive(child: DeckListScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = ref.watch(contentProfileProvider);
    final pages = _pagesFor(content);
    // key 选择：profile 变化后选中 key 仍有效则保持，失效回落首页（不错位）。
    final keys = pages.map((p) => p.key).toSet();
    if (!keys.contains(_selectedKey)) _selectedKey = 'home';
    return DeskShell(
      items: pages.map((p) => p.key).toList(),
      selectedKey: _selectedKey,
      onSelectKey: (k) => setState(() => _selectedKey = k),
      child: pages.firstWhere((p) => p.key == _selectedKey).page,
    );
  }
}

/// IndexedStack keepAlive 包装：壳内切换页面时不销毁状态
/// （autoDispose provider 的计时器/会话在切页后存活）。
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

/// 首页内容（站外壳主区第一项）：猫问候 + 引导卡 + 今日总览 + 五猫速览。
class _HomeContent extends ConsumerWidget {
  /// 点五猫速览卡 → 切到对应模块页（与左栏同一导航，不 push 路由）。
  final void Function(String moduleKey)? onOpenModule;
  const _HomeContent({this.onOpenModule});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cat = ref.watch(catProvider);
    final profile = ref.watch(userProfileProvider);
    final content = ref.watch(contentProfileProvider);
    final days = profile.daysToExam;
    final visibleModules =
        DeskShell.catModules.where((m) => content.hasModule(m.$5)).toList();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        // 专属标题：「小明 · 北京大学 新闻与传播」（未填则「三猫书桌 · 考研」）
        title: Text(profile.setupDone && profile.titleLine != '三猫书桌'
            ? profile.titleLine
            : '三猫书桌 · 考研'),
        actions: [
          if (days != null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(
                child: Text('距考试 $days 天',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
          // 一键导入 .smpack 专属资源包（客户交付模式）
          const PackImportButton(compact: true),
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OnboardingScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _CatGreeting(
            mood: cat.mood,
            intimacy: cat.intimacy,
            today: cat.todayReviewed,
            nickname: profile.nickname,
          ),
          const SizedBox(height: 12),
          const PackGuideCard(), // 未装专属包时显示导入引导（装了自动消失）
          const _TodayOverview(), // 跨模块今日总览
          const SizedBox(height: 12),
          // 五猫速览（点击切到对应模块页——与左栏同一导航，不再 push 新路由，
          // 修复审查回归③：壳内嵌屏不再叠加返回箭头/双 AppBar）
          for (final m in visibleModules)
            Card(
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: m.$4,
                  child: Icon(m.$3, color: Colors.white),
                ),
                title: Text(m.$1),
                subtitle: Text(m.$2),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onOpenModule?.call(m.$5),
              ),
            ),
          const SizedBox(height: 8),
          Center(
            child: Text(content.displayName,
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
  final String nickname;
  const _CatGreeting({
    required this.mood,
    required this.intimacy,
    required this.today,
    this.nickname = '',
  });

  @override
  Widget build(BuildContext context) {
    final hasReviewedToday = today > 0;
    final who = nickname.isEmpty ? '' : '$nickname，';
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
                      ? '${who}今天复习了 $today 张，猫咪很满足～'
                      : '${who}猫咪在等你今天来复习哦！',
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
