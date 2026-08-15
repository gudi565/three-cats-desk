import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/local_only_backend.dart';
import 'package:three_cats_desk/core/profile/content_profile.dart';
import 'package:three_cats_desk/core/profile/profile_notifier.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/features/wenwen/quiz_importer.dart';
import 'package:three_cats_desk/features/shell/desk_shell.dart';
import 'package:three_cats_desk/features/shell/agent_screen.dart';
import 'package:three_cats_desk/features/shell/knowledge_screen.dart';

/// 站外壳（左栏导航）widget 测试（DeepTutor 形态，2026-08-15）。
///
/// 钉死：侧栏结构（品牌区/我的书桌区/五猫区）、五猫按 profile 开关过滤、
/// 切换导航、全中文文案、三入口屏渲染。
Widget _wrap(Widget child, AppDatabase db, {ContentProfile? profile}) {
  return ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      cloudSyncProvider.overrideWithValue(LocalOnlyBackend()),
      if (profile != null)
        contentProfileProvider.overrideWith((ref) {
          final n =
              ProfileNotifier(db, DeckImporter(db), QuizImporter(db));
          // 直接设置 state（测试注入指定 profile）
          n.state = profile;
          return n;
        }),
    ],
    child: MaterialApp(home: child),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('侧栏含品牌区/我的书桌四项/五猫五项（standard 全开）', (tester) async {
    tester.view.physicalSize = const Size(1400, 900); // 宽屏 → 固定侧栏
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    await tester.pumpWidget(_wrap(
      DeskShell(
          items: ['home','agent','knowledge','notebook','niannian','nuannuan','wenwen','zhizhi','yuanyuan'],
          selectedKey: 'home',
          onSelectKey: (_) {},
          child: const Text('主区')),
      db,
    ));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('三猫书桌'), findsWidgets); // 品牌区
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('考研智能体'), findsOneWidget);
    expect(find.text('知识库'), findsOneWidget);
    expect(find.text('笔记本'), findsOneWidget);
    expect(find.text('念念'), findsOneWidget);
    expect(find.text('暖暖'), findsOneWidget);
    expect(find.text('稳稳'), findsOneWidget);
    expect(find.text('知知'), findsOneWidget);
    expect(find.text('渊渊'), findsOneWidget);
    expect(find.text('主区'), findsOneWidget);
  });

  testWidgets('五猫按 profile 模块开关过滤（关掉则不显示）', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    // 只开念念+稳稳的 profile
    const partial = ContentProfile(
      id: 'partial', displayName: '部分', basePath: '',
      modules: ['niannian', 'wenwen'],
    );
    await tester.pumpWidget(_wrap(
      DeskShell(
          items: ['home','agent','knowledge','niannian','wenwen'],
          selectedKey: 'home',
          onSelectKey: (_) {},
          child: const Text('主区')),
      db,
      profile: partial,
    ));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('念念'), findsOneWidget); // 开
    expect(find.text('稳稳'), findsOneWidget); // 开
    expect(find.text('暖暖'), findsNothing); // 关
    expect(find.text('知知'), findsNothing); // 关
    expect(find.text('渊渊'), findsNothing); // 关
    expect(find.text('笔记本'), findsNothing); // zhizhi 关→笔记本入口也关
  });

  testWidgets('点侧栏切换触发 onSelect', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    String? selected;
    await tester.pumpWidget(_wrap(
      DeskShell(
          items: ['home','agent','knowledge','notebook','niannian','nuannuan','wenwen','zhizhi','yuanyuan'],
          selectedKey: 'home',
          onSelectKey: (k) => selected = k,
          child: const Text('主区')),
      db,
    ));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('考研智能体'));
    await tester.pump();
    expect(selected, 'agent'); // desk 区第二项
  });

  testWidgets('智能体/知识库占位屏渲染（全中文，无报错）', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    await tester.pumpWidget(_wrap(const AgentScreen(), db));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('考研智能体'), findsOneWidget);
    expect(find.textContaining('错题'), findsWidgets);

    await tester.pumpWidget(_wrap(const KnowledgeScreen(), db));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('知识库'), findsOneWidget);
    expect(find.textContaining('还没有内置资料'), findsOneWidget); // 空库提示
  });
}
