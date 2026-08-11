import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/features/cat/cat_provider.dart';

void main() {
  group('CatState 心情档位映射', () {
    test('intimacy 阈值 → 正确的 CatMood（1a 要前几张卡就感知猫变化）', () {
      expect(const CatState(intimacy: 0).mood, CatMood.sleepy);
      expect(const CatState(intimacy: 1).mood, CatMood.idle);
      expect(const CatState(intimacy: 2).mood, CatMood.idle);
      expect(const CatState(intimacy: 3).mood, CatMood.thinking);
      expect(const CatState(intimacy: 7).mood, CatMood.thinking);
      expect(const CatState(intimacy: 8).mood, CatMood.happy);
      expect(const CatState(intimacy: 19).mood, CatMood.happy);
      expect(const CatState(intimacy: 20).mood, CatMood.encouraging);
      expect(const CatState(intimacy: 999).mood, CatMood.encouraging);
    });

    test('level 每 5 张卡升一级', () {
      expect(const CatState(intimacy: 0).level, 1);
      expect(const CatState(intimacy: 4).level, 1);
      expect(const CatState(intimacy: 5).level, 2);
      expect(const CatState(intimacy: 12).level, 3);
    });

    test('copyWith 不传的字段保持原值', () {
      final s = const CatState(intimacy: 7, todayReviewed: 3, todayDate: '2026-08-12');
      expect(s.copyWith(intimacy: 8).todayReviewed, 3);
      expect(s.copyWith(todayReviewed: 4).intimacy, 7);
    });
  });

  group('CatMood 枚举', () {
    test('5 态齐全（对齐设计文档 CatMood）', () {
      expect(CatMood.values.length, 5);
      // 每态都有非空 label/emoji，UI 渲染不炸。
      for (final m in CatMood.values) {
        expect(m.label.isNotEmpty, true, reason: '$m label 空');
        expect(m.emoji.isNotEmpty, true, reason: '$m emoji 空');
      }
    });
  });
}
