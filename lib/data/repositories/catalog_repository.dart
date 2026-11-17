import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/config.dart';
import '../../core/network/api_exception.dart';
import '../local/daos.dart';
import '../models/manga.dart';
import '../models/settings.dart';
import '../remote/catalog_api.dart';
import '../services/download_manager.dart';

/// Catalog access with an offline fallback: titles that were opened once stay
/// browsable without network, and downloaded chapters are read from disk.
class CatalogRepository {
  CatalogRepository({
    required this.api,
    required this.titleCache,
    required this.kv,
    required this.downloads,
    required this.settings,
  });

  final CatalogApi api;
  final TitleCacheDao titleCache;
  final KvDao kv;
  final DownloadManager downloads;
  final AppSettings Function() settings;

  List<SourceInfo>? _sources;

  Future<List<SourceInfo>> sources({bool refresh = false}) async {
    if (_sources != null && !refresh) return _sources!;
    try {
      final list = await api.sources(includeNsfw: true);
      await kv.set('sources_cache', jsonEncode([
        for (final s in list)
          {
            'id': s.id,
            'name': s.name,
            'base_url': s.baseUrl,
            'is_nsfw': s.isNsfw,
            'notes': s.notes,
            'capabilities': {
              'search': s.caps.search,
              'genre_filter': s.caps.genreFilter,
              'genre_exclude': s.caps.genreExclude,
              'type_filter': s.caps.typeFilter,
              'status_filter': s.caps.statusFilter,
              'sort_orders': [for (final o in s.caps.sortOrders) o.api],
            },
            'genres': [for (final g in s.genres) {'id': g.id, 'name': g.name}],
          }
      ]));
      return _sources = list;
    } on ApiException {
      final raw = await kv.get('sources_cache');
      if (raw == null) rethrow;
      return _sources = [for (final s in jsonDecode(raw) as List) SourceInfo.fromJson((s as Map).cast())];
    }
  }

  /// Sources the user wants to see (NSFW toggle + disabled list).
  Future<List<SourceInfo>> enabledSources() async {
    final s = settings();
    return [
      for (final src in await sources())
        if ((s.showNsfw || !src.isNsfw) && !s.disabledSources.contains(src.id)) src,
    ];
  }

  Future<SourceInfo?> source(String id) async {
    for (final s in await sources()) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<MangaPage> browse(String sourceId, {int page = 1, CatalogFilters filters = const CatalogFilters(), CancelToken? cancel}) =>
      api.browse(sourceId, page: page, filters: filters, cancel: cancel);

  Future<(List<HomeSection>, List<SourceFailure>)> home(String sourceId) => api.home(sourceId);

  Future<SearchResults> search(String query,
      {int page = 1, List<String>? sources, CatalogFilters filters = const CatalogFilters(), CancelToken? cancel}) async {
    final s = settings();
    final enabled = sources ?? [for (final src in await enabledSources()) src.id];
    return api.search(
      query: query,
      page: page,
      sources: enabled,
      includeNsfw: s.showNsfw,
      filters: filters.copyWith(excludeGenres: {...filters.excludeGenres}.toList()),
      cancel: cancel,
    );
  }

  /// Network first (with cache refresh), falling back to the local copy.
  Future<TitleData> title(String sourceId, String mangaId, {bool refresh = false}) async {
    if (!refresh) {
      final cached = await titleCache.get(sourceId, mangaId);
      if (cached != null && DateTime.now().toUtc().difference(cached.$2) < AppConfig.titleCacheTtl) {
        return cached.$1;
      }
    }
    try {
      final data = await api.title(sourceId, mangaId, refresh: refresh);
      await titleCache.put(data);
      return data;
    } on ApiException {
      final cached = await titleCache.get(sourceId, mangaId);
      if (cached != null) return cached.$1;
      rethrow;
    }
  }

  /// Local files for downloaded chapters, otherwise signed URLs from the server.
  Future<List<PageRef>> pages(String sourceId, String chapterId) async {
    final local = await downloads.localPages(sourceId, chapterId);
    if (local != null) return local;
    return api.pages(sourceId, chapterId, width: settings().imageQuality.width);
  }
}
