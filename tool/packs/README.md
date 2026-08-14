# .smpack 资源包生成器（卖家端）

## 交付模式

客户拿到的 App 是**同一个通用原型**（内置公共课词书，开箱可用）。
你按客户的专业/院校/书目生成专属 `.smpack` 资源包发给他，
他在 App 里点「导入我的专属资源包」选文件即完成内置——
词书、题库、考纲、文献全部就位，模块开关自动生效。

## 生成一个包

```bash
cd three-cats-desk
dart run tool/make_pack.dart tool/packs/kaoyan_art.yaml
# 自定义输出名（发客户用）：
dart run tool/make_pack.dart tool/packs/my_client.yaml -o 客户-张三.smpack
```

产物落在 `build/packs/<id>.smpack`，直接发给客户（微信/网盘均可）。

## 配置文件写法（tool/packs/*.yaml）

```yaml
id: client_zhangsan          # 唯一 id（重装判重用，别重复）
displayName: 张三的北大新传备考包
suggestSchool: 北京大学       # 装包后自动预填到他的档案
suggestMajor: 新闻与传播
examDate: 2026-12-26          # 可选；自动预填倒计时
modules: [niannian, nuannuan, wenwen, zhizhi, yuanyuan]  # 缺省全开；不考数学就关 wenwen 之类按需裁剪
decks:                        # 念念词书（.ncpack 或 .json）
  - /Users/serein/Desktop/《三猫书桌》/04_内容与题库/背诵卡/美术/中外美术史.ncpack
questions:                    # 稳稳题库（JSON 数组；题目须真题/人产，解析自制）
  - ./quiz/politics.json
syllabus: ./syllabus/xinchuan.md   # 可选；装成知知预置笔记，条目可一键转念念卡
literature: ./lit/xinchuan.json    # 可选；渊渊预置文献（DOI 判重）
```

## 质量门（生成前强制，不通过不出包）

- 每本词书必须能解析且卡数 > 0（防止把坏文件发给客户）
- 每道题 id/stem/options≥2/answerIndex 合法
- examDate 必须是 YYYY-MM-DD

## 内容红线（定价与法律风险，见深研报告）

- 题目只能来自真题/书后题改造，**解析必须自制**（题库刑事判例：复制第三方题干+选项+解析销售获刑）
- 词书释义自制核查（GLM 产卡 118 处硬伤教训）
- 真题原文/公开考纲可用；第三方题库解析/整卷禁搬

## 客户侧安装（他要做的全部）

打开 App → 首页右上 ⬇️（或首启向导里「导入我的专属资源包」）→ 选文件 →
看到「✅ 已安装 XX包：词书×7 · 题目×20 · 考纲」即完成。重复导入幂等不翻倍。
