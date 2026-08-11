import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'core/providers.dart';
import 'core/supabase_client.dart';
import 'features/niannian/login_screen.dart';
import 'features/niannian/review_screen.dart';

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
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const _modules = [
    ('念念', '背书 · 翻卡复习', Icons.style_outlined, Color(0xFF3E8EAA), true),
    ('暖暖', '专注', Icons.local_cafe_outlined, Color(0xFFE0A458), false),
    ('稳稳', '做题', Icons.checklist_outlined, Color(0xFF5B9E6F), false),
    ('知知', '笔记', Icons.edit_note_outlined, Color(0xFFB083C9), false),
    ('渊渊', '文献', Icons.menu_book_outlined, Color(0xFF8B7E6A), false),
  ];

  @override
  Widget build(BuildContext context) {
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
                onTap: m.$5
                    ? () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const DeckListScreen()),
                        )
                    : null,
              ),
            ),
          const SizedBox(height: 16),
          const Center(
            child: Text('Phase0 · 念念翻卡最小闭环',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
