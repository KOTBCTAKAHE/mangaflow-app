import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../data/models/manga.dart';
import '../../data/remote/catalog_api.dart';

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

  bool get isIdle => query.trim().isEmpty && filters.genres.isEmpty;

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
      );
}

/// Debounced global search; a new query cancels the in-flight request.
class MangaSearchController extends StateNotifier<SearchState> {
  MangaSearchController(this.ref) : super(SearchState(filters: CatalogFilters(excludeGenres: ref.read(settingsProvider).excludedGenres)));

  final Ref ref;
  Timer? _debounce;
  CancelToken? _cancel;

  void setQuery(String q) {
    state = state.copyWith(query: q);
    _debounce?.cancel();
    if (state.isIdle) {
      _cancel?.cancel();
      state = state.copyWith(items: const [], errors: const [], loading: false, hasNext: false, page: 0, error: () => null);
      return;
    }
    _debounce = Timer(AppConfig.searchDebounce, () => _run(reset: true));
  }

  void submit() {
    _debounce?.cancel();
    if (state.query.trim().isNotEmpty) ref.read(searchHistoryDaoProvider).add(state.query);
    _run(reset: true);
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
    if (!state.hasNext || state.loading || state.loadingMore) return;
    await _run(reset: false);
  }

  Future<void> _run({required bool reset}) async {
    if (state.isIdle) return;
    _cancel?.cancel();
    final token = _cancel = CancelToken();
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
    } on ApiException catch (e) {
      if (e.code == 'cancelled' || token.isCancelled) return;
      state = state.copyWith(loading: false, loadingMore: false, error: () => e);
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
