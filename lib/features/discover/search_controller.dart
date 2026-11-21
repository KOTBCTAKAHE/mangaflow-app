import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../data/models/manga.dart';
import '../../data/remote/catalog_api.dart';
import '../../data/remote/discover_api.dart';

class SearchState {
  const SearchState({
    this.query = '',
    this.filters = const CatalogFilters(),
    this.sources,
    this.items = const [],
    this.errors = const [],
    this.page = 0,
    this.hasNext = false,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.plot = false,
    this.plotHits = const [],
    this.plotIndexed = 0,
  });

  final String query;
  final CatalogFilters filters;

  /// null = all enabled sources
  final List<String>? sources;
  final List<MangaCard> items;
  final List<SourceFailure> errors;
  final int page;
  final bool hasNext;
  final bool loading;
  final bool loadingMore;
  final Object? error;

  /// «По сюжету»: the query is a description, matched against title plots on the server.
  final bool plot;
  final List<PlotHit> plotHits;
  final int plotIndexed;

  bool get isIdle => plot ? query.trim().length < 3 : query.trim().isEmpty && filters.genres.isEmpty;

  /// Several words with no luck by name — probably a plot description.
  bool get looksLikePlot => !plot && query.trim().split(RegExp(r'\s+')).length >= 3;

  SearchState copyWith({
    String? query,
    CatalogFilters? filters,
    List<String>? Function()? sources,
    List<MangaCard>? items,
    List<SourceFailure>? errors,
    int? page,
    bool? hasNext,
    bool? loading,
    bool? loadingMore,
    Object? Function()? error,
    bool? plot,
    List<PlotHit>? plotHits,
    int? plotIndexed,
  }) =>
      SearchState(
        query: query ?? this.query,
        filters: filters ?? this.filters,
        sources: sources != null ? sources() : this.sources,
        items: items ?? this.items,
        errors: errors ?? this.errors,
        page: page ?? this.page,
        hasNext: hasNext ?? this.hasNext,
        loading: loading ?? this.loading,
        loadingMore: loadingMore ?? this.loadingMore,
        error: error != null ? error() : this.error,
        plot: plot ?? this.plot,
        plotHits: plotHits ?? this.plotHits,
        plotIndexed: plotIndexed ?? this.plotIndexed,
      );
}

/// Debounced global search; a new query cancels the in-flight request.
class MangaSearchController extends StateNotifier<SearchState> {
  MangaSearchController(this.ref) : super(SearchState(filters: CatalogFilters(excludeGenres: ref.read(settingsProvider).excludedGenres)));

  final Ref ref;
  Timer? _debounce;
  CancelToken? _cancel;

  void setQuery(String q) {
    if (autoPlot && state.plot && q.trim().split(RegExp(r'\s+')).length < 4) {
      autoPlot = false;
      state = state.copyWith(plot: false, plotHits: const []);
    }
    state = state.copyWith(query: q);
    _debounce?.cancel();
    if (state.isIdle) {
      _cancel?.cancel();
      state = state.copyWith(items: const [], plotHits: const [], errors: const [], loading: false, hasNext: false, page: 0,
          error: () => null);
      return;
    }
    // a plot description is typed slowly: search it on a longer pause (or on «Найти»)
    _debounce = Timer(state.plot ? const Duration(milliseconds: 1200) : AppConfig.searchDebounce, () => _run(reset: true));
  }

  void submit() {
    _debounce?.cancel();
    final incognito = ref.read(settingsProvider).incognito;
    if (state.query.trim().isNotEmpty && !incognito) ref.read(searchHistoryDaoProvider).add(state.query);
    _run(reset: true);
  }

  void setPlotMode(bool on, {bool byUser = false}) {
    if (byUser) autoPlot = false;
    if (on == state.plot) return;
    _cancel?.cancel();
    state = state.copyWith(plot: on, items: const [], plotHits: const [], errors: const [], page: 0, hasNext: false,
        loading: false, loadingMore: false, error: () => null);
    if (!state.isIdle) _run(reset: true);
  }

  void setFilters(CatalogFilters f) {
    state = state.copyWith(filters: f);
    if (!state.isIdle) _run(reset: true);
  }

  void setSources(List<String>? ids) {
    state = state.copyWith(sources: () => ids);
    if (!state.isIdle) _run(reset: true);
  }

  Future<void> loadMore() async {
    if (state.plot || !state.hasNext || state.loading || state.loadingMore) return;
    await _run(reset: false);
  }

  Future<void> _run({required bool reset}) async {
    if (state.isIdle) return;
    _cancel?.cancel();
    final token = _cancel = CancelToken();
    if (state.plot) return _runPlot(token);
    final page = reset ? 1 : state.page + 1;
    state = reset
        ? state.copyWith(loading: true, error: () => null, items: const [], errors: const [])
        : state.copyWith(loadingMore: true);
    try {
      final res = await ref.read(catalogRepositoryProvider).search(
            state.query.trim(),
            page: page,
            sources: state.sources,
            filters: state.filters,
            cancel: token,
          );
      if (token.isCancelled) return;
      final seen = {for (final i in state.items) i.key};
      state = state.copyWith(
        items: reset ? res.items : [...state.items, ...res.items.where((i) => !seen.contains(i.key))],
        errors: res.errors,
        page: page,
        hasNext: res.hasNext,
        loading: false,
        loadingMore: false,
      );
      // one search box for everything: a description that matches no name is searched by plot
      if (reset && res.items.isEmpty && state.query.trim().split(RegExp(r'\s+')).length >= 4 && state.filters.genres.isEmpty) {
        autoPlot = true;
        setPlotMode(true);
      }
    } on ApiException catch (e) {
      if (e.code == 'cancelled' || token.isCancelled) return;
      state = state.copyWith(loading: false, loadingMore: false, error: () => e);
    }
  }

  /// The last switch to «По сюжету» was made by the search itself (nothing found by name).
  bool autoPlot = false;

  Future<void> _runPlot(CancelToken token) async {
    state = state.copyWith(loading: true, error: () => null, plotHits: const []);
    try {
      final r = await ref.read(discoverApiProvider).plotSearch(
            state.query.trim(),
            includeNsfw: ref.read(settingsProvider).showNsfw,
            cancel: token,
          );
      if (token.isCancelled || !state.plot) return;
      state = state.copyWith(plotHits: r.items, plotIndexed: r.indexed, loading: false);
    } on ApiException catch (e) {
      if (e.code == 'cancelled' || token.isCancelled) return;
      state = state.copyWith(loading: false, error: () => e);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancel?.cancel();
    super.dispose();
  }
}

final searchControllerProvider =
    StateNotifierProvider<MangaSearchController, SearchState>((ref) => MangaSearchController(ref));

final searchHistoryProvider = FutureProvider<List<String>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(searchHistoryDaoProvider).recent();
});
