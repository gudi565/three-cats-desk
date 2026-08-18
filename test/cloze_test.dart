import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/features/niannian/cloze.dart';

/// C2 Cloze 填空卡渲染验证（Anki {{cN::}} 语法三猫版）。
void main() {
  test('合法性判定', () {
    expect(Cloze.isValid('{{c1::气韵生动}}是谢赫六法之首'), isTrue);
    expect(Cloze.isValid('普通卡没有挖空'), isFalse);
    expect(Cloze.isValid('{{c1::}}'), isFalse, reason: '空挖空不合法');
  });

  test('正面渲染：挖空处占位', () {
    final f = Cloze.renderFront('{{c1::气韵生动}}是谢赫六法之首');
    expect(f, '［……］是谢赫六法之首');
    expect(f.contains('气韵生动'), isFalse);
  });

  test('背面渲染：完整原文+被挖词加粗', () {
    final b = Cloze.renderBack('{{c1::气韵生动}}是谢赫六法之首');
    expect(b, '**气韵生动**是谢赫六法之首');
    expect(b.contains('{{'), isFalse);
  });

  test('多挖空提取答案', () {
    final a = Cloze.answers('{{c1::骨法用笔}}与{{c2::应物象形}}');
    expect(a, ['骨法用笔', '应物象形']);
  });

  test('混合中英文与特殊字符', () {
    const front = '{{c1::FSRS}} 算法的全称是 {{c2::Free Spaced Repetition Scheduler}}';
    expect(Cloze.isValid(front), isTrue);
    expect(Cloze.renderFront(front), '［……］ 算法的全称是 ［……］');
    expect(Cloze.renderBack(front), contains('**FSRS**'));
    expect(Cloze.answers(front).length, 2);
  });
}
