# 三猫书桌 · Flutter 工程（Phase 1a）

1 App 五模块（暖暖专注/念念背书/稳稳做题/知知笔记/渊渊文献），先 Web + 安卓验证，iOS 后上。
**Phase 1a 目标**：ship 给 10 个真实考研人，验证「用户会不会为了猫第二天再打开」这个 hook。
范围严控：只做念念翻卡能用 + 猫养成最小闭环；门控次日留存≥30% 才进 1b。

## 运行

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # 重新生成 database.g.dart（改 tables.dart 后必跑）

flutter test                                       # 全部（fsrs + niannian 闭环 + 猫养成，23 测）

flutter run -d chrome                               # Web 开发
flutter run -d android                              # 安卓开发
```

### Web 构建（本地与 CI 通用）

```bash
bash scripts/build_web.sh
# = flutter build web --release + 自动注入 canvaskit 本地加载
```

**国内网络坑**：canvaskit.wasm 默认从 `gstatic.com` CDN 加载（不可达）→ 白屏。
`build_web.sh` 在 build 后跑 `scripts/fix_canvaskit.py`，给 `flutter_bootstrap.js`
注入 `config.canvasKitBaseUrl:"/canvaskit/"`，让 .wasm 从本地加载（build 已拷到该目录）。
> 每次 `flutter build web` 会覆盖 flutter_bootstrap.js，所以**务必用 build_web.sh 而非裸 build**。

起静态服务本地验证：

```bash
cd build/web && python3 -m http.server 8099   # http://127.0.0.1:8099
```

## 部署（GitHub Actions → Pages + APK）

`.github/workflows/build.yml`：push 到 main 自动跑 test → build web → deploy GitHub Pages，
并行 build APK（artifact 可下载）。首次需在 repo Settings → Pages → Source 选 "GitHub Actions"。

## 架构

```
lib/
  main.dart                      # bootstrap（导入词书→drift）+ 五模块骨架 + go_router + 首屏猫问候条
  core/
    fsrs.dart                    # FSRS-6 手译（19 权重, clampS NaN 兜底, _seed 用 _imul32 跨端一致）
    supabase_client.dart         # Supabase 初始化（url+anonKey）
    cloud_sync.dart              # drift → Supabase cards 表（PUSH/PULL, local-first）
    deck_importer.dart           # assets 词书导入（JSON / .ncpack zip, contentHash 判重）
    providers.dart               # Riverpod 全局单例
    db/                          # drift 表 local_decks / local_cards + 生成代码
  features/
    cat/                         # 猫养成（Phase 1a）
      cat_provider.dart          # intimacy=累计复习次数(只增), SharedPreferences, 5 态映射
      pixel_cat.dart             # 程序化 8-bit 像素猫(CustomPainter, 零依赖)
    niannian/                    # 念念翻卡 + 评分
      review_screen.dart         # 翻卡 UI + 顶部猫进度条 + 完成态猫庆祝
      review_provider.dart       # FSRS 评分闭环, onGraded 接 catProvider
      deck_provider.dart login_screen.dart
    {nuannuan,wenwen,zhizhi,yuanyuan}/  # 留空，1b 后填
assets/decks/                    # 词书（熟词僻义.ncpack / 考研英语核心词组.ncpack / english-kaoyan-hifi.json）
scripts/
  build_web.sh                   # build + canvaskit fix（本地/CI 通用）
  fix_canvaskit.py               # 注入 canvasKitBaseUrl
test/                            # fsrs + niannian + cat_provider
```

## 猫养成（Phase 1a 核心 hook）

验证「为猫第二天再打开」。设计依据 `06_UI设计与素材/.../猫互动系统设计.md` 方案 C（程序化像素猫）。

- **intimacy = 累计复习次数，只增不衰减**：复习一张卡 → +1（不区分评分档位）。
  反焦虑：考研人群敏感，衰减/扣分会攻击情绪。次日留存看「打开」行为，卡片仍按 FSRS 排期。
- **5 态心情**：sleepy(0)/idle(1-2)/thinking(3-7)/happy(8-19)/encouraging(20+)，阈值刻意低，
  让用户前几张卡就感知猫变化。
- **像素猫**：Canvas 网格矩阵画，呼吸/happy跳/眨眼/sleepy飘zZ/happy飘心。零外部资源（不用 Rive：
  无 .riv 资产 + rive.app GUI 不可程序化操作）。
- 1a 不做跨设备同步猫进度（验证 hook 不需要），不做撸猫/喂猫交互（留 1b）。

## Supabase

- 连接信息：`lib/core/supabase_client.dart`（url + publishable anonKey，项目 `wbopbcjrxmsvsinttrdz`）。
- **service_role 绝不入端**（铁律）。anon key 公开安全（RLS 保护）。
- schema 见 `../phase0-supabase-schema.sql`。local-first：未登录/无网/表未建 → 云调用静默跳过。

## FSRS（关键）

手译自 legacy `ThreeCatsKit/Sources/CatSRS/FSRS.swift`（**非** pub.dev fsrs 包——后者 21 参数与 legacy 19 参数不一致，会导致跨端同卡排期不同）。
NaN 守卫（iOS 致命#1 教训）：`clampS()` 对 NaN/±Inf/0/负兜到 S_MIN。
