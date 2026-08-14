import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/profile/content_profile.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/features/wenwen/quiz_importer.dart';

/// 当前激活的内容包 profile（按人定制的运行态）。
///
/// 启动时：尝试加载「客户定制 profile」目录；找不到 → 回落到 `ContentProfile.standard`
/// （公共课词书 + 示例题库，全部猫启用）。这保证 App 永远可用，客户版只是内容更多/更专。
///
/// 客户版怎么来：构建时把定制 profile 目录打进 assets（如 assets/profiles/<客户id>/），
/// 并把目录名写进 `_bundledProfileDirs`。100 个客户 = 100 个 assets 目录 + 同一份代码。
class ProfileNotifier extends StateNotifier<ContentProfile> {
  final AppDatabase db;
  final DeckImporter deckImporter;
  final QuizImporter quizImporter;

  /// 启动时要探测的客户 profile 目录（构建定制版时在此登记）。
  /// 通用版留空 → 直接用 standard。
  static const _bundledProfileDirs = <String>[
    'assets/profiles/kaoyan_art', // 美术考研·国美方向（首个定制包）
  ];

  ProfileNotifier(this.db, this.deckImporter, this.quizImporter)
      : super(ContentProfile.standard);

  bool _imported = false;

  /// 探测并加载第一个可用的客户 profile；导入其内容（幂等）。找不到 → 保持 standard。
  Future<void> loadAndImport() async {
    if (_imported) return; // 防重复导入（热重载/重建）
    _imported = true;
    ContentProfile chosen = ContentProfile.standard;
    for (final dir in _bundledProfileDirs) {
      final p = await ProfileLoader.loadFromAssets(dir);
      if (p != null) {
        chosen = p;
        break; // 取第一个可用客户包
      }
    }
    state = chosen;
    final importer = ProfileImporter(db, deckImporter, quizImporter);
    await importer.importProfile(chosen);
  }

  /// 是否启用某只猫（模块开关，首页据此显示）。
  bool hasModule(String module) => state.hasModule(module);
}

final contentProfileProvider =
    StateNotifierProvider<ProfileNotifier, ContentProfile>((ref) {
  return ProfileNotifier(
    ref.watch(appDatabaseProvider),
    ref.watch(deckImporterProvider),
    ref.watch(quizImporterProvider),
  );
});
