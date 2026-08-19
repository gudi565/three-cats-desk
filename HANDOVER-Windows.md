# 三猫书桌 · Windows 电脑转交提示词

> 2026-08-19 · 由 Mac（当前开发机）转 Windows 新机
> 转交包：`三猫书桌-转交包-2026-08-19.zip`（839MB，桌面）——含全部代码/文档/内容库，已排除 build 缓存

---

## 你是谁、接手的是什么

你接手「三猫书桌」——一个已经能跑的**本地考研智能体站**（Flutter），不是从零开始。当前状态：

- **代码**：GitHub `gudi565/three-cats-desk`（main 分支 = 最新，commit `fa40a99`），134/134 测试绿，CI 六 job 全绿
- **产品形态**：1 个 App 五猫模块（念念 FSRS 背书含 Cloze 填空 / 暖暖番茄专注 / 稳稳做题判分含真题维度 / 知知笔记即卡片 / 渊渊文献逐句溯源）+ DeepTutor 形态左栏站外壳 + 考研智能体（agent loop / 深度讲解 solve 脊柱 / 四槽画像 / BM25 中文检索）
- **商业模式**：通用原型 App（免费发）+ .smpack 专属资源包（卖家 CLI 按客户专业生成，一键导入）+ 本地部署无云端
- **转交包含**：工程（.git 在）、全部策划/深研/决策文档、13 学科内容库（04_内容与题库）、产卡工具、UI 素材、legacy iOS 工程（01_代码工程，只读参考勿动）

## 第一步：环境搭建（Windows）

```powershell
# 1. Flutter（用 Git Bash 或 PowerShell）
# 下载 https://docs.flutter.dev/get-started/install/windows → 解压到 C:\flutter → PATH 加 C:\flutter\bin
flutter doctor          # 按提示补 Android Studio / Visual Studio（桌面构建需要 VS C++ 工作负载）
git --version           # 需要 git

# 2. 拉代码（推荐——转交包里的 .git 也可以直接用，但 GitHub 是真相源）
git clone https://github.com/gudi565/three-cats-desk.git
cd three-cats-desk
flutter pub get
dart run build_runner build    # 生成 drift 代码（database.g.dart 已在库里，重跑一次保险）

# 3. 验证
flutter test                   # 应 134/134 全绿
flutter run -d windows         # 桌面版直接跑起来
flutter build windows --release  # 产物在 build\windows\x64\runner\Release\
```

**账号/凭据**（需要从原机转移或重设）：
- GitHub 账号 `gudi565`（push 权限）——新机上 `gh auth login` 或配 SSH key
- 智谱 API key（智能体用）：**不在代码库里**（安全设计：flutter_secure_storage 存本机钥匙串）。从 https://open.bigmodel.cn 控制台拿，App 内 模型设置→填入。测试用的 key：`d0b72387209e4b8aa94a07981c87a739.9Asqt4vxBuCHErvm`（仅开发测试，正式交付让客户用自己的）
- Supabase 项目 `wbopbcjrxmsvsinttrdz`（云端版用，本地版默认不碰）

## 必读文档（按序，都在转交包根目录）

1. **`三猫书桌-项目总结与新生大纲-2026-08-13.md`** —— 三代全史 + **防重启宪法**（不换栈/不重写/验证门控只砍不加）
2. `三猫书桌-智能体站融合方案-2026-08-15.md` —— 当前形态的设计蓝图
3. `三猫书桌-架构完善方案v2-2026-08-15.md` —— 架构纪律（依赖方向/密钥/工具防错）
4. `三猫书桌-竞品功能内置决策方案-2026-08-17.md` —— 13 款竞品裁决 + C1-C3 已落地记录
5. `tool/packs/README.md`（工程内）—— .smpack 卖家交付流程

## 当前下一步（按优先级）

1. **L1 首客验证（最高优先，只有用户本人能做）**：找 1 个真实美术考研人 → 发 Windows 包 + 用 `tool/packs/kaoyan_art.yaml` 生成 .smpack 发他 → 他导入用起来。门控：单客交付工时 ≤3 天 + 7 日留存。**功能已经远超验证需要，别再加功能**
2. C4 .apkg 导入（接入 Anki 共享牌组生态，~2 天）
3. C5 知知 OPML 导入导出 / C6 暖暖树皮肤（~1.5 天）
4. 出题管线（**先看决策方案 §四的版权红线**：真题原文可用、解析必须自制；深研标注出题质检缺文献支撑，做前先专项补研）

## 工程纪律（血泪换的，别踩）

- **改完必须跑**：`flutter test` 全绿 + `flutter build web --release`（analyze 有缓存漏检前科——import 改动 analyze 绿但 web 编译挂）→ push → 等 CI 六 job 全绿
- **drift 加表/列**：改 `lib/core/db/tables.dart` + `database.dart`（schemaVersion+1 和迁移分支）→ `dart run build_runner build`。**列名禁用 text/value/key**（撞 drift builder 名会静默生成空壳 g.dart 不报错）
- **git push 偶发 HTTP/2 抽风**：报错后 `git fetch` 再看真实状态（多数实际已推上）
- **密钥红线**：API key 只走 flutter_secure_storage，绝不进代码/备份/.smpack
- 每完成一块 → commit（信息写清楚依据文档哪节）→ push。别攒大包

## 记忆系统说明（这台 Mac 上的资产）

原机的 Claude 持久记忆（`~/.claude/projects/.../memory/`）有全部会话沉淀——转交包不含它（在用户目录外）。**关键结论已全部写进项目根的文档**，新机 Claude 首次会话读上面 5 篇文档即可接上。若要完整迁移记忆，另拷 `~/.claude/projects/-Users-serein-Desktop-------/memory/` 目录。

## 常用命令速查

```bash
# 测试/构建
flutter test && flutter build web --release && flutter build windows --release

# 生成客户资源包（改 tool/packs/kaoyan_art.yaml 或复制一份新配置）
dart run tool/make_pack.dart tool/packs/客户.yaml -o 客户名.smpack

# 云端版构建（默认 local 无云；云端版加参数）
flutter build apk --dart-define=SANMAO_MODE=cloud

# 真模型测试（设环境变量后跑 live 测试）
# PowerShell: $env:ZHIPU_KEY="..."; flutter test test/agent_live_test.dart
```

---

*打包执行：Claude（2026-08-19）。工程最后状态：fa40a99，134/134 绿，CI 六 job 绿，远程与本地一致。*
