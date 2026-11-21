import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/network/network_status.dart';
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

  /// `source/chapter` → the same chapter on other sources (from merged titles).
  final _alts = <String, List<ChapterAlt>>{};

  void _remember(String sourceId, TitleData d) {
    for (final c in d.chapters) {
      if (c.alts.isNotEmpty) _alts['$sourceId/${c.id}'] = c.alts;
    }
  }

  /// One title, every source: chapters the title's own source lacks come from the others.
  /// Null when switched off, offline or nothing to add; the result is cached like [title].
  Future<TitleData?> merged(String sourceId, String mangaId) async {
    if (!settings().mergeSources || sourceId == 'local') return null;
    try {
      final d = await api.merged(sourceId, mangaId);
      if (d.chapters.isEmpty) return null;
      await titleCache.put(d);
      _remember(sourceId, d);
      return d;
    } catch (_) {
      return null;
    }
  }

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
        if ((s.showNsfw || !src.isNsfw) && !s.disabledSources.contains(src.id) && s.sourceLanguages.contains(src.lang)) src,
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
        _remember(sourceId, cached.$1);
        return cached.$1;
      }
    }
    try {
      var data = await api.title(sourceId, mangaId, refresh: refresh);
      // keep the chapters other sources added last time until the merged list is fetched again
      final prev = settings().mergeSources ? (await titleCache.get(sourceId, mangaId))?.$1 : null;
      if (prev != null) {
        final have = {for (final c in data.chapters) c.number};
        final keep = [for (final c in prev.chapters) if (c.isForeign && c.number != null && !have.contains(c.number)) c];
        if (keep.isNotEmpty) {
          final all = [...data.chapters, ...keep];
          final numbered = all.where((c) => c.number != null).toList()..sort((a, b) => b.number!.compareTo(a.number!));
          data = TitleData(manga: data.manga, chapters: [...numbered, ...all.where((c) => c.number == null)]);
        }
      }
      await titleCache.put(data);
      _remember(sourceId, data);
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
    final pages = local ?? await _remotePages(sourceId, chapterId);
    return [for (final p in pages) p.withKey('$sourceId/$chapterId/${p.index}')];
  }

  /// The chapter's own source first; when that site fails, the same chapter elsewhere.
  Future<List<PageRef>> _remotePages(String sourceId, String chapterId) async {
    final width = effectivePageWidth(settings());
    try {
      return await api.pages(sourceId, chapterId, width: width);
    } catch (e) {
      final alts = _alts['$sourceId/$chapterId'] ?? const <ChapterAlt>[];
      if (alts.isEmpty) rethrow;
      for (final a in alts) {
        try {
          return await api.pages(a.sourceId, a.chapterId, width: width);
        } catch (_) {}
      }
      rethrow;
    }
  }
}
