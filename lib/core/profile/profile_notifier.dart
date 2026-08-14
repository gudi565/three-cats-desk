import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/profile/content_profile.dart';
import 'package:three_cats_desk/core/profile/pack_installer.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/features/wenwen/quiz_importer.dart';

/// 当前激活的内容包 profile（按人定制的运行态）。
///
/// 通用原型模式（2026-08-14 客户交付模式）：
///   - App = 同一个通用原型（内置公共课词书 + 示例题库 = standard 兜底）。
///   - 客户买后收到 .smpack 专属资源包 → App 里点一下导入 → applyPack 激活。
///   - 激活态持久化（SharedPreferences），下次启动恢复——模块开关/包名/院校专业建议全生效。
///
/// 卖家侧用 tool/make_pack.dart 按专业生成 .smpack（内容生成不进 App）。
class ProfileNotifier extends StateNotifier<ContentProfile> {
  static const _kInstalled = 'profile.installed_pack_json';

  final AppDatabase db;
  final DeckImporter deckImporter;
  final QuizImporter quizImporter;

  ProfileNotifier(this.db, this.deckImporter, this.quizImporter)
      : super(ContentProfile.standard) {
    _restoreInstalled();
  }

  bool _bootstrapped = false;

  /// 冷启动：恢复已安装包（若有）+ 导入 standard 公共课内容（幂等）。
  /// 客户包内容不重导——安装时已进 drift，词书/题库自带判重。
  Future<void> loadAndImport() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    final importer = ProfileImporter(db, deckImporter, quizImporter);
    await importer.importProfile(ContentProfile.standard);
    // 已装客户包的内容已在安装时导入 drift，这里只恢复激活态。
  }

  /// 运行时安装 .smpack 资源包（UI 一次点击触发）。
  /// 安装内容进 drift + 激活为当前 profile + 持久化。返回安装摘要。
  Future<PackInstallResult> applyPack(List<int> packBytes) async {
    final installer = PackInstaller(db, deckImporter, quizImporter);
    final result = await installer.installFromBytes(packBytes);
    state = result.profile;
    await _persistInstalled(result.profile);
    return result;
  }

  /// 恢复安装态：冷启动时从 SharedPreferences 读上次激活的包。
  Future<void> _restoreInstalled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kInstalled);
      if (raw == null || raw.isEmpty) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      List<String> l(String k) =>
          (m[k] as List?)?.map((e) => e.toString()).toList() ?? const [];
      state = ContentProfile(
        id: m['id'] as String? ?? 'custom',
        displayName: m['displayName'] as String? ?? '我的专属包',
        suggestSchool: m['suggestSchool'] as String? ?? '',
        suggestMajor: m['suggestMajor'] as String? ?? '',
        examDate: m['examDate'] as String? ?? '',
        modules: l('modules').isEmpty
            ? const ['niannian', 'nuannuan', 'wenwen', 'zhizhi', 'yuanyuan']
            : l('modules'),
        decks: const [],
        questions: const [],
        basePath: '',
      );
    } catch (_) {
      // 恢复失败保持 standard，不破启动
    }
  }

  Future<void> _persistInstalled(ContentProfile p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kInstalled, jsonEncode({
      'id': p.id,
      'displayName': p.displayName,
      'suggestSchool': p.suggestSchool,
      'suggestMajor': p.suggestMajor,
      'examDate': p.examDate,
      'modules': p.modules,
    }));
  }

  /// 是否启用某只猫（模块开关，首页据此显示）。
  bool hasModule(String module) => state.hasModule(module);

  /// 是否已安装专属包（UI：未装时显示引导卡）。
  bool get hasCustomPack => state.id != ContentProfile.standard.id;
}

final contentProfileProvider =
    StateNotifierProvider<ProfileNotifier, ContentProfile>((ref) {
  return ProfileNotifier(
    ref.watch(appDatabaseProvider),
    ref.watch(deckImporterProvider),
    ref.watch(quizImporterProvider),
  );
});
