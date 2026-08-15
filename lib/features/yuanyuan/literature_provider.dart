import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:three_cats_desk/core/cross_app_cards.dart';
import 'package:three_cats_desk/core/db/database.dart';
import 'package:three_cats_desk/core/providers.dart';
import 'package:uuid/uuid.dart';

import '../../core/deck_providers.dart';
import 'literature_search.dart';

/// 渊渊文献模块。
///
/// MVP 闭环：CrossRef 真实检索 → 加入文献库 → 摘要/批注摘录 → 一键转念念复习卡。
/// 铁律：绝不 AI 造文献——文献来自真实 CrossRef API / 手动录入。
/// RAG「问你的文献」依赖后端 pgvector，未部署 → 诚实留口（检索仍可用）。

final literatureSearchServiceProvider = Provider((ref) => LiteratureSearchService());

/// 文献库列表（新更新在前）。
final literatureListProvider = FutureProvider<List<LiteratureData>>((ref) async {
  ref.watch(literatureRevisionProvider);
  return ref.watch(appDatabaseProvider).getLiteratureList();
});

/// 修订号：增删改后自增，触发列表刷新。
final literatureRevisionProvider = StateProvider<int>((ref) => 0);

/// 检索状态（query + 结果 + loading）。
class LiteratureSearchState {
  final String query;
  final List<CrossRefHit> hits;
  final bool loading;
  const LiteratureSearchState({this.query = '', this.hits = const [], this.loading = false});

  LiteratureSearchState copyWith({String? query, List<CrossRefHit>? hits, bool? loading}) =>
      LiteratureSearchState(
        query: query ?? this.query,
        hits: hits ?? this.hits,
        loading: loading ?? this.loading,
      );
}

class LiteratureSearchNotifier extends StateNotifier<LiteratureSearchState> {
  final LiteratureSearchService service;
  LiteratureSearchNotifier(this.service) : super(const LiteratureSearchState());

  Future<void> search(String query) async {
    state = state.copyWith(query: query, loading: true);
    final hits = await service.search(query);
    state = state.copyWith(hits: hits, loading: false);
  }

  void clear() => state = const LiteratureSearchState();
}

final literatureSearchProvider =
    StateNotifierProvider.autoDispose<LiteratureSearchNotifier, LiteratureSearchState>(
        (ref) => LiteratureSearchNotifier(ref.watch(literatureSearchServiceProvider)));

/// 把一条检索命中文献加入文献库（按 DOI 去重）。返回是否新加。
/// ref 放宽为 dynamic（provider 层 Ref / screen 层 WidgetRef 皆可，都有 read()）。
Future<bool> addHitToLibrary(dynamic ref, CrossRefHit hit) async {
  final db = ref.read(appDatabaseProvider);
  if (hit.doi.isNotEmpty) {
    final existing = await db.getLiteratureByDoi(hit.doi);
    if (existing != null) return false; // 已入库
  }
  final id = const Uuid().v4();
  await db.upsertLiterature(LiteratureCompanion.insert(
    id: id,
    title: hit.title,
    authors: Value(hit.authors),
    year: Value(hit.year),
    venue: Value(hit.venue),
    doi: Value(hit.doi),
    url: Value(hit.url),
    abstractText: Value(hit.abstractText),
    source: const Value('crossref'),
    sourceApp: const Value('yuanyuan'),
    synced: const Value(false),
  ));
  // 上云（异步）
  final lit = await db.getLiteratureById(id);
  if (lit != null) await ref.read(cloudSyncProvider).pushLiterature(lit);
  ref.read(literatureRevisionProvider.notifier).state++;
  return true;
}

/// 摘录/批注 → 念念复习卡（文献摘录即卡片，type=highlight, source_app=yuanyuan）。
/// 进念念"跨猫卡箱"复习队列——这是渊渊对 Zotero/知网研学的差异化（摘录→背书）。
Future<void> literatureToCard(dynamic ref,
    {required String literatureId, required String title, required String excerpt}) async {
  final front = '[渊渊·文献] $title';
  final back = excerpt.trim().isEmpty ? '（无摘录）' : excerpt.trim();
  await CrossAppCards.add(ref, front: front, back: back,
      sourceApp: 'yuanyuan', type: 'highlight', sourceRef: literatureId);
  ref.read(literatureRevisionProvider.notifier).state++;
}
