/// 应用运行模式（本地专属版 vs 云端同步版）。
///
/// 这是「本地部署 + 按人定制」方向（2026-08-13）的架构总开关。
/// 编译期常量，构建时注入：
///   flutter build apk --dart-define=SANMAO_MODE=local    # 本地专属版（默认）
///   flutter build apk --dart-define=SANMAO_MODE=cloud    # 云端同步版
///
/// 设计要点：
/// - 默认 **local**——新方向的默认交付形态是无云端的本地专属系统。
/// - cloud 模式保留完整 Supabase 同步（现役行为），代码不删，作为将来的升级档/多人版退路。
/// - 模式只影响「同步后端」和「是否初始化 Supabase」，五猫业务逻辑完全不感知模式。
class AppMode {
  AppMode._();

  /// 编译期注入的运行模式：'local'（默认）或 'cloud'。
  static const String _raw =
      String.fromEnvironment('SANMAO_MODE', defaultValue: 'local');

  /// 是否云端同步模式（false = 本地专属版，默认）。
  static const bool isCloud = _raw == 'cloud';

  /// 是否本地专属模式（默认 true）。本地模式下不初始化 Supabase、不做任何云同步。
  static const bool isLocal = !isCloud;

  /// 展示用模式名。
  static const String name = isCloud ? 'cloud' : 'local';
}
