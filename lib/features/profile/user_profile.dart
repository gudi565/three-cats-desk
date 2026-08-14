import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地专属档案（本地部署方向的「账号」替代品，2026-08-13）。
///
/// 无云端 = 无账号系统。但「专属考研系统」的专属感必须有个载体：
/// 首次启动让用户填 昵称 / 目标院校 / 专业方向 / 考试日期，
/// 存在本地 SharedPreferences，从此首页/猫问候/开机语都带上他的名字与目标——
/// 「XX 的北大新传备考系统」。这也是轻度防盗绑定（嵌入用户身份，转卖变尴尬）。
///
/// 设计要点：
/// - 无账号、无密码、无网络，纯本地。`setupDone=false` 时首页跳到初始化向导。
/// - 考试日期用于倒计时（专属感最强的元素之一："距考试还有 N 天"）。
/// - 与猫命名空间（cat_provider 的 bindUser）解耦：本地模式只有一个用户，命名空间用 '_local'。
class UserProfile {
  final String nickname; // 昵称（"小明"）
  final String school; // 目标院校（"北京大学"）
  final String major; // 专业方向（"新闻与传播"）
  final String examDate; // 考试日期 YYYY-MM-DD（可空串=未设）
  final bool setupDone; // 是否已完成初始化向导

  const UserProfile({
    this.nickname = '',
    this.school = '',
    this.major = '',
    this.examDate = '',
    this.setupDone = false,
  });

  /// 展示用专属标题："小明 · 北京大学 新闻与传播"。
  String get titleLine {
    final parts = <String>[
      if (nickname.isNotEmpty) nickname,
      if (school.isNotEmpty) school,
      if (major.isNotEmpty) major,
    ];
    return parts.isEmpty ? '三猫书桌' : parts.join(' · ');
  }

  /// 距考试天数（未设日期/已过期返回 null）。
  int? get daysToExam {
    if (examDate.isEmpty) return null;
    final d = DateTime.tryParse(examDate);
    if (d == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final exam = DateTime(d.year, d.month, d.day);
    final diff = exam.difference(today).inDays;
    return diff >= 0 ? diff : null;
  }

  UserProfile copyWith({
    String? nickname,
    String? school,
    String? major,
    String? examDate,
    bool? setupDone,
  }) =>
      UserProfile(
        nickname: nickname ?? this.nickname,
        school: school ?? this.school,
        major: major ?? this.major,
        examDate: examDate ?? this.examDate,
        setupDone: setupDone ?? this.setupDone,
      );
}

class UserProfileNotifier extends StateNotifier<UserProfile> {
  static const _kNickname = 'profile.nickname';
  static const _kSchool = 'profile.school';
  static const _kMajor = 'profile.major';
  static const _kExamDate = 'profile.exam_date';
  static const _kSetupDone = 'profile.setup_done';

  UserProfileNotifier() : super(const UserProfile()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = UserProfile(
      nickname: prefs.getString(_kNickname) ?? '',
      school: prefs.getString(_kSchool) ?? '',
      major: prefs.getString(_kMajor) ?? '',
      examDate: prefs.getString(_kExamDate) ?? '',
      setupDone: prefs.getBool(_kSetupDone) ?? false,
    );
  }

  /// 保存档案（初始化向导提交 / 设置页修改）。
  Future<void> save(UserProfile p) async {
    state = p;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kNickname, p.nickname);
    await prefs.setString(_kSchool, p.school);
    await prefs.setString(_kMajor, p.major);
    await prefs.setString(_kExamDate, p.examDate);
    await prefs.setBool(_kSetupDone, p.setupDone);
  }
}

final userProfileProvider =
    StateNotifierProvider<UserProfileNotifier, UserProfile>((ref) {
  return UserProfileNotifier();
});
