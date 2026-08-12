import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/deck_importer.dart';
import 'package:three_cats_desk/core/fsrs.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:uuid/uuid.dart';

import '../cat/cat_provider.dart';
import '../niannian/deck_provider.dart';

/// 稳稳做题模块。
///
/// 核心闭环：作答 → 客观判分(0 LLM) → 写 attempts。
///   对 → 计入 correct。
///   错 → 【套装差异化】自动生成一张念念 FSRS 复习卡（写 cards, type=error, source_app=wenwen），
///         进念念"跨猫卡箱"复习队列——错题→背书，这是稳稳对疯狂刷题的唯一结构性优势。

/// 题库列表（启动时 bootstrap 导入 assets/questions）。
final questionListProvider = FutureProvider<List<Question>>((ref) async {
  return ref.watch(appDatabaseProvider).getAllQuestions();
});

/// 错题本（isCorrect=false 的作答，新在前）。
final wrongAttemptsProvider = FutureProvider<List<Attempt>>((ref) async {
  ref.watch(quizRevisionProvider);
  return ref.watch(appDatabaseProvider).getWrongAttempts();
});

/// 修订号：作答后自增，触发错题本/进度刷新。
final quizRevisionProvider = StateProvider<int>((ref) => 0);

/// 一套题的做题会话状态。
class QuizSession {
  final List<Question> questions;
  final int index;
  final int? selected;      // 当前题已选（null=未答）
  final bool revealed;      // 已判定显示对错+解析
  final int correctCount;
  final bool finished;

  const QuizSession({
    required this.questions,
    this.index = 0,
    this.selected,
    this.revealed = false,
    this.correctCount = 0,
    this.finished = false,
  });

  Question? get current => index < questions.length ? questions[index] : null;
  int get total => questions.length;

  QuizSession copyWith({int? index, int? selected, bool? revealed, int? correctCount, bool? finished, bool clearSelected = false}) =>
      QuizSession(
        questions: questions,
        index: index ?? this.index,
        selected: clearSelected ? null : (selected ?? this.selected),
        revealed: revealed ?? this.revealed,
        correctCount: correctCount ?? this.correctCount,
        finished: finished ?? this.finished,
      );
}

class QuizController extends StateNotifier<QuizSession> {
  final AppDatabase db;
  final Future<void> Function(Attempt attempt, Question q)? onAttempted; // 上云
  final Future<void> Function(Question q)? onWrongToCard; // 错题→念念卡
  final void Function()? onAllDone; // 全部做完喂猫

  static const _uuid = Uuid();

  QuizController(this.db, List<Question> questions,
      {this.onAttempted, this.onWrongToCard, this.onAllDone})
      : super(QuizSession(questions: questions));

  /// 选一个选项并判定（客观判分 0 LLM）。
  Future<void> answer(int optionIndex) async {
    final q = state.current;
    if (q == null || state.revealed) return;
    final options = _options(q);
    if (optionIndex < 0 || optionIndex >= options.length) return;
    final correct = optionIndex == q.answerIndex;

    final attempt = Attempt(
      id: _uuid.v4(),
      questionId: q.id,
      selectedIndex: optionIndex,
      isCorrect: correct,
      answeredAt: DateTime.now(),
      sourceApp: 'wenwen',
      synced: false,
    );
    await db.insertAttempt(attempt.toCompanion(true));

    state = state.copyWith(
      selected: optionIndex,
      revealed: true,
      correctCount: state.correctCount + (correct ? 1 : 0),
    );

    // 上云（异步，local-first）
    final oc = onAttempted;
    if (oc != null) oc(attempt, q);

    // 错题 → 念念复习卡（异步）
    if (!correct) {
      final wc = onWrongToCard;
      if (wc != null) await wc(q);
    }
  }

  /// 下一题；到底则结算。
  Future<void> next() async {
    if (state.index + 1 >= state.total) {
      state = state.copyWith(finished: true);
      onAllDone?.call();
    } else {
      state = state.copyWith(index: state.index + 1, clearSelected: true, revealed: false);
    }
  }

  List<String> _options(Question q) =>
      (jsonDecode(q.optionsJson) as List).map((e) => e.toString()).toList();
}

/// 做题会话 provider（按 subject 分组一套题）。
final quizControllerProvider = StateNotifierProvider.autoDispose
    .family<QuizController, QuizSession, String>((ref, subject) {
  // 该 subject 的题（同步快照——若空则 watch 后由 UI 兜 loading）。
  final all = ref.watch(questionListProvider).value ?? <Question>[];
  final qs = subject == '全部' ? all : all.where((q) => q.subject == subject).toList();
  return QuizController(
    ref.watch(appDatabaseProvider),
    qs,
    onAttempted: (attempt, q) => ref.read(cloudSyncProvider).pushAttempt(attempt, q),
    onWrongToCard: (q) => _wrongToCard(ref, q),
    onAllDone: () => ref.read(catProvider.notifier).onFocusCompleted(),
  );
});

/// 错题→念念复习卡（写 cards: type=error, source_app=wenwen → 进念念跨猫卡箱）。
Future<void> _wrongToCard(Ref ref, Question q) async {
  final db = ref.read(appDatabaseProvider);
  final cardId = const Uuid().v4();
  final front = '[稳稳·错题] ${q.stem}';
  final opts = (jsonDecode(q.optionsJson) as List).map((e) => e.toString()).toList();
  final correct = q.answerIndex >= 0 && q.answerIndex < opts.length ? opts[q.answerIndex] : '';
  final back = '正确答案：${String.fromCharCode(65 + q.answerIndex)}. $correct\n解析：${q.explanation ?? ''}';

  final fsrs = FsrsCard(id: cardId);
  final companion = LocalCardsCompanion(
    id: Value(cardId),
    deckId: const Value.absent(),
    type: const Value('error'),
    front: Value(front),
    back: Value(back),
    sourceApp: const Value('wenwen'),
    fsrsState: Value(jsonEncode(fsrs.toJson())),
    due: Value(fsrs.due),
    state: Value(fsrs.state.value),
    synced: const Value(false),
  );
  await db.insertCards([companion]);
  // 上云（念念 cards 表，wenwen 卡）
  final card = LocalCard(
    id: cardId, deckId: null, type: 'error', front: front, back: back,
    sourceApp: 'wenwen', fsrsState: jsonEncode(fsrs.toJson()),
    due: fsrs.due, state: fsrs.state.value, synced: false, updatedAt: DateTime.now(),
  );
  await ref.read(cloudSyncProvider).pushCard(card, fsrs);
  // 触发念念 deck 列表刷新
  ref.read(deckRevisionProvider.notifier).state++;
}
