# 三猫书桌 · Flutter 工程（Phase0）

1 App 五模块（暖暖专注/念念背书/稳稳做题/知知笔记/渊渊文献），先 Web + 安卓验证，iOS 后上。
Phase0 目标：念念翻卡最小闭环（deck 列表 → 翻卡 → FSRS 4 键评分 → drift 本地 + 异步上云 Supabase）。

## 运行

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 重新生成 database.g.dart（改 tables.dart 后必跑）

flutter test test/fsrs_test.dart                  # FSRS + NaN 守卫（12 测）
flutter test test/niannian_integration_test.dart  # 念念闭环（导入→drift→FSRS→更新，4 测）

flutter build web --release   # Web
flutter run -d chrome         # Web 开发（或 -d android）
```

### Web 运行（本地验证）

`flutter build web` 产出 `build/web/`。**国内网络坑**：canvaskit.wasm 默认从 `gstatic.com` CDN 加载（不可达）→ 白屏。
解决：build 后编辑 `build/web/flutter_bootstrap.js`，在 `_flutter.loader.load({` 后加 `config: { canvasKitBaseUrl: "/canvaskit/" }`，
让 canvaskit 从本地 `/canvaskit/` 加载（build 已把 canvaskit.wasm 拷到该目录）。起静态服务：

```bash
cd build/web && python3 -m http.server 8099   # http://127.0.0.1:8099
```

> ⚠ 每次 `flutter build web` 会覆盖 flutter_bootstrap.js，需重新注入。后续可固化成脚本。

## 架构

```
lib/
  main.dart                      # bootstrap（导入词书→drift）+ 五模块骨架 + go_router
  core/
    fsrs.dart                    # FSRS-6 手译（19 权重, clampS NaN 兜底, _seed 用 32 位 FNV）
    supabase_client.dart         # Supabase 初始化（url+anonKey from legacy Backend.swift）
    cloud_sync.dart              # drift → Supabase cards 表（PUSH/PULL, local-first）
    deck_importer.dart           # assets 词书导入（JSON / .ncpack zip, contentHash 判重）
    providers.dart               # Riverpod 全局单例
    db/
      tables.dart                # drift 表 local_decks / local_cards
      database.dart              # AppDatabase
      database.g.dart            # 生成代码（build_runner）
      connection_stub/_io/_web.dart  # 条件导入避 dart:ffi 在 Web 静态引入
  features/niannian/             # 念念（Phase0 唯一实现）
    deck_provider.dart review_provider.dart review_screen.dart login_screen.dart
  features/{nuannuan,wenwen,zhizhi,yuanyuan}/  # 留空，后续阶段填
assets/decks/                    # 词书（熟词僻义.ncpack / 考研英语核心词组.ncpack / english-kaoyan-hifi.json）
web/sqlite3.wasm, web/drift_worker.js  # Web drift sqlite3 wasm 资源（从 drift 包拷）
test/                            # fsrs_test.dart + niannian_integration_test.dart
```

## Supabase

- 连接信息：`lib/core/supabase_client.dart`（url + publishable anonKey，项目 `wbopbcjrxmsvsinttrdz`）。
- **service_role 绝不入端**（铁律）。
- schema 见 `../phase0-supabase-schema.sql`（subject_nodes + cards + decks，一键执行，幂等）。在 Supabase Dashboard → SQL Editor 跑。
- local-first：未登录 / 无网 / cards 表未建 → 云调用静默跳过，drift 本地不破。

## FSRS（关键）

手译自 legacy `ThreeCatsKit/Sources/CatSRS/FSRS.swift`（**非** pub.dev fsrs 包——后者 21 参数与 legacy 19 参数不一致，会导致跨端同卡排期不同）。
NaN 守卫（iOS 致命#1 教训）：`clampS()` 对 NaN/±Inf/0/负兜到 S_MIN(0.001)，单测在 `test/fsrs_test.dart`。

## 安卓

需 JDK 17+（本机默认 Java 8 不够）+ Android SDK（已装 `android-commandlinetools`）。
JDK 装好后：`flutter doctor --android-licenses` 接受协议，`sdkmanager` 装 platform-tools/build-tools/platforms，建 AVD。
