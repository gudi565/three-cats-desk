import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:three_cats_desk/core/cloud_sync.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:three_cats_desk/features/cat/cat_provider.dart';
import 'package:three_cats_desk/features/niannian/review_provider.dart';

/// review → cat 链路保护测试（审计发现：删掉 review_provider.dart 的 catProvider.onCardReviewed()
/// 这行，测试仍全绿——核心 hook 无保护）。本测试让「评分 → intimacy+1」有回归覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 让 CatNotifier 的 SharedPreferences 在纯 test 环境可用（内存 mock）。
    SharedPreferences.setMockInitialValues({});
  });

  test('wiring：评分一张卡 → intimacy +1（review→cat 闭环）', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    // 插一张今日到期卡（fsrsState 是合法 FsrsCard json）。
    final card = FsrsCard(id: 'w1');
    await db.insertCards([
      LocalCardsCompanion(
        id: const Value('w1'),
        deckId: const Value('d1'),
        front: const Value('f'),
        back: const Value('b'),
        fsrsState: Value(jsonEncode(card.toJson())),
        due: Value(DateTime.now()),
        state: const Value(0),
        synced: const Value(false),
      ),
    ]);

    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      // CloudSync 未初始化 Supabase → _canSync=false → pushCard no-op，不触网。
      cloudSyncProvider.overrideWithValue(CloudSync(db)),
    ]);
    addTearDown(container.dispose);

    // 触发并保持 controller 存活（autoDispose），等 _load 完成。
    final sub = container.listen(reviewControllerProvider('d1'), (_, __) {});
    addTearDown(sub.close);
    for (var i = 0;
        i < 100 && container.read(reviewControllerProvider('d1')).queue.isEmpty;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(container.read(reviewControllerProvider('d1')).queue, isNotEmpty,
        reason: '_load 应装入今日到期卡');

    final before = container.read(catProvider).intimacy;
    await container
        .read(reviewControllerProvider('d1').notifier)
        .grade(FsrsRating.good);

    expect(container.read(catProvider).intimacy, before + 1,
        reason: '评分成功后 review_provider 的 onGraded 必须让 catProvider.intimacy +1');
  });
}
