import 'package:flutter_test/flutter_test.dart';
import 'package:three_cats_desk/core/app_mode.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/local_only_backend.dart';

/// SyncBackend 接口化 + 本地专属后端的行为验证。
///
/// 背景（2026-08-13 本地部署方向）：三猫 local-first，云只是镜像。
/// 本地专属版把云去掉，五猫业务代码通过 SyncBackend 抽象零改动运行。
/// 这里钉死两件事：
///   1. 默认运行模式是 local（本地专属是新方向默认形态）。
///   2. LocalOnlyBackend 全部 no-op、返回「未同步」语义（push*=false / pull=0），
///      绝不抛异常——保证五猫在无网/无云下照常跑，且卡保持 synced=false
///      （将来切回云端版时能被 pushAllUnsynced 自然补齐）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppMode 默认本地专属', () {
    test('未注入 SANMAO_MODE 时默认 local（非 cloud）', () {
      // 测试进程不带 --dart-define，应回落到 defaultValue='local'。
      expect(AppMode.isLocal, isTrue);
      expect(AppMode.isCloud, isFalse);
      expect(AppMode.name, 'local');
    });
  });

  group('LocalOnlyBackend 全 no-op（本地专属不触碰云）', () {
    final backend = LocalOnlyBackend();

    test('pushCard 返回 false（未上云）且不抛', () async {
      final card = LocalCard(
        id: 'c1',
        type: 'qa',
        front: 'f',
        sourceApp: 'niannian',
        fsrsState: '{}',
        due: DateTime.now(),
        state: 0,
        synced: false,
        updatedAt: DateTime.now(),
      );
      final fsrs = FsrsCard(id: 'c1');
      expect(await backend.pushCard(card, fsrs), isFalse);
    });

    test('其余 push* 全部返回 false 且不抛', () async {
      final now = DateTime.now();
      expect(
        await backend.pushNote(Note(
            id: 'n1',
            title: 't',
            content: 'c',
            subject: '',
            sourceApp: 'zhizhi',
            synced: false,
            archived: false,
            updatedAt: now,
            createdAt: now)),
        isFalse,
      );
      expect(
        await backend.pushLiterature(LiteratureData(
            id: 'l1',
            title: 't',
            authors: '',
            year: '',
            venue: '',
            doi: '',
            url: '',
            abstractText: '',
            note: '',
            source: 'manual',
            sourceApp: 'yuanyuan',
            synced: false,
            archived: false,
            updatedAt: now,
            createdAt: now)),
        isFalse,
      );
      expect(
        await backend.pushFocusSession(FocusSession(
            id: 'f1',
            startedAt: now,
            plannedMinutes: 25,
            actualSeconds: 1500,
            completed: true,
            sourceApp: 'nuannuan',
            synced: false,
            updatedAt: now)),
        isFalse,
      );
      expect(
        await backend.pushAttempt(
          Attempt(
              id: 'a1',
              questionId: 'q1',
              selectedIndex: 0,
              isCorrect: true,
              answeredAt: now,
              sourceApp: 'wenwen',
              synced: false),
          Question(
              id: 'q1',
              stem: 's',
              optionsJson: '["A","B"]',
              answerIndex: 0,
              subject: '政治',
              source: '',
              sourceApp: 'wenwen',
              createdAt: now),
        ),
        isFalse,
      );
    });

    test('pull / pushAllUnsynced / markActivity 全部安全 no-op', () async {
      expect(await backend.pullDeck('deck-1'), 0);
      expect(await backend.pushAllUnsynced(), 0);
      await backend.markActivity(intimacy: 42); // 不抛即通过
    });
  });
}
