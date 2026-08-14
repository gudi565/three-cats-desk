import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:three_cats_desk/features/profile/user_profile.dart';

/// 本地专属档案（UserProfile）行为验证。
///
/// 本地部署方向（2026-08-13）：无账号系统，档案是"专属感"的载体。
/// 钉死：保存/重载往返、titleLine 拼接、考试倒计时、setupDone 标记。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('UserProfile 纯逻辑', () {
    test('titleLine 拼接 昵称·院校·专业，空字段跳过', () {
      const p = UserProfile(nickname: '小明', school: '北京大学', major: '新闻与传播');
      expect(p.titleLine, '小明 · 北京大学 · 新闻与传播');
      const onlyNick = UserProfile(nickname: '小明');
      expect(onlyNick.titleLine, '小明');
      const empty = UserProfile();
      expect(empty.titleLine, '三猫书桌');
    });

    test('daysToExam：未来日期返回正数，过期/空/非法返回 null', () {
      final future = DateTime.now().add(const Duration(days: 100));
      final ds = '${future.year}-${future.month.toString().padLeft(2, '0')}-${future.day.toString().padLeft(2, '0')}';
      expect(UserProfile(examDate: ds).daysToExam, 100);
      expect(const UserProfile(examDate: '2020-01-01').daysToExam, isNull); // 已过
      expect(const UserProfile(examDate: '').daysToExam, isNull); // 空
      expect(const UserProfile(examDate: 'not-a-date').daysToExam, isNull); // 非法
    });
  });

  group('UserProfileNotifier 持久化', () {
    test('保存后可从 SharedPreferences 重载（含 setupDone）', () async {
      final n1 = UserProfileNotifier();
      await n1.save(const UserProfile(
        nickname: '阿梅',
        school: '国美',
        major: '美术史',
        examDate: '2026-12-26',
        setupDone: true,
      ));
      // 新建 notifier 模拟冷启动重载
      final n2 = UserProfileNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(n2.state.nickname, '阿梅');
      expect(n2.state.school, '国美');
      expect(n2.state.major, '美术史');
      expect(n2.state.examDate, '2026-12-26');
      expect(n2.state.setupDone, isTrue);
    });

    test('默认 setupDone=false（首启应进向导）', () async {
      final n = UserProfileNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(n.state.setupDone, isFalse);
    });
  });
}
