import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/features/yuanyuan/literature_chunks.dart';

/// C1 逐句溯源验证：chunk 锚点入库 → 检索带引用 → 校验器抓瞎编。
void main() {
  late AppDatabase db;
  late LiteratureChunker chunker;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chunker = LiteratureChunker(db);
    await db.upsertLiterature(LiteratureCompanion.insert(
      id: 'lit1',
      title: '谢赫六法与中国绘画理论',
      abstractText: const Value('气韵生动为第一法'),
    ));
  });
  tearDown(() async => db.close());

  test('切段带锚点：段落序/偏移/超长段二次切句', () async {
    const text = '气韵生动是谢赫六法之首。\n\n骨法用笔次之。\n\n'
        '第三应物象形，第四随类赋彩，第五经营位置，第六传移模写。'
        '这六法构成中国古代绘画品评的核心框架。'
        '历代画论对六法的阐释不断演化，形成了完整的理论体系。'
        '现代学者从美学与技法两个维度重新审视六法的当代价值。'
        '其中气韵生动被视为最高审美标准，贯穿千年画论传统。'
        '骨法用笔则关联书法用笔的传统，体现书画同源。';

    final n = await chunker.chunkAndStore('lit1', text);
    final chunks = await db.getChunks('lit1');
    expect(chunks.length, greaterThanOrEqualTo(3));
    // 锚点递增
    expect(chunks.first.paraIndex, 0);
    expect(chunks.first.offsetStart, 0);
    // 段落序单调不减
    for (var i = 1; i < chunks.length; i++) {
      expect(chunks[i].paraIndex, greaterThanOrEqualTo(chunks[i - 1].paraIndex));
    }
    // 超长段被切句：单段 >500 字符拆成多 chunk 同 paraIndex
    final longPara = '这是一段超长的测试文本。' * 120; // ~1440 字符 → 触发二次切句
    final n2 = await chunker.chunkAndStore('lit1', longPara);
    final rechunks = await db.getChunks('lit1');
    expect(rechunks.length, greaterThan(1), reason: '超长段应二次切句');
  });

  test('检索带引用锚点：ref 格式《标题》¶N', () async {
    await chunker.chunkAndStore('lit1',
        '气韵生动是谢赫六法之首，指作品和作品中刻画的形象具有一种生动的气度韵致。');
    final hits = await chunker.searchChunks('气韵生动');
    expect(hits, isNotEmpty);
    expect(hits.first.ref, contains('《谢赫六法与中国绘画理论》'));
    expect(hits.first.ref, contains('¶1'));
    expect(hits.first.body, contains('气韵生动'));
    expect(hits.first.toToolJson()['ref'], contains('¶')); // 工具 JSON 带 ref
  });

  test('逐句校验器：支撑句通过，瞎编句被降级标注', () {
    final provided = {
      '《X》¶1': '气韵生动是谢赫六法之首，指作品的气度韵致。',
    };
    // 支撑句（n-gram 高重叠）→ 不标
    final ok = CitationChecker.check(
      '画论认为气韵生动是谢赫六法之首《X》¶1。', provided);
    expect(ok, isNot(contains('⚠️')));

    // 瞎编句（与 chunk 无重叠）→ 标警告（引注在句首，claim 跟在引注后）
    final bad = CitationChecker.check(
      '《X》¶1据研究量子力学与光合作用存在纠缠关联。', provided);
    expect(bad, contains('⚠️'));

    // 引用不存在的锚点 → 硬标注
    final ghost = CitationChecker.check('某观点《不存在》¶9。', provided);
    expect(ghost, contains('引用不存在'));
  });
}
