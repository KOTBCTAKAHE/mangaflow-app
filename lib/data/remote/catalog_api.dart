import 'package:dio/dio.dart';

import '../../core/network/api_client.dart';
import '../../core/network/image_urls.dart';
import '../models/manga.dart';

class CatalogFilters {
  const CatalogFilters({
    this.query = '',
    this.sort = SortMode.popular,
    this.genres = const [],
    this.excludeGenres = const [],
    this.kinds = const [],
    this.statuses = const [],
  });

  final String query;
  final SortMode sort;
  final List<String> genres;
  final List<String> excludeGenres;
  final List<MangaKind> kinds;
  final List<PubStatus> statuses;

  bool get isEmpty => query.isEmpty && genres.isEmpty && excludeGenres.isEmpty && kinds.isEmpty && statuses.isEmpty;
  int get activeCount => genres.length + excludeGenres.length + kinds.length + statuses.length;

  CatalogFilters copyWith({
    String? query,
    SortMode? sort,
    List<String>? genres,
    List<String>? excludeGenres,
    List<MangaKind>? kinds,
    List<PubStatus>? statuses,
  }) =>
      CatalogFilters(
        query: query ?? this.query,
        sort: sort ?? this.sort,
        genres: genres ?? this.genres,
        excludeGenres: excludeGenres ?? this.excludeGenres,
        kinds: kinds ?? this.kinds,
        statuses: statuses ?? this.statuses,
      );

  Map<String, dynamic> toQuery() => {
        'q': query,
        'sort': sort.api,
        'genres': genres,
        'exclude_genres': excludeGenres,
        'types': [for (final k in kinds) k.api],
        'statuses': [for (final s in statuses) s.api],
      };
}

/// `/sources`, `/manga`, `/chapters`, `/search`.
class CatalogApi {
  CatalogApi(this.client);
  final ApiClient client;

  Future<List<SourceInfo>> sources({bool includeNsfw = false}) => client.get('/sources',
      query: {'include_nsfw': includeNsfw},
      parse: (d) => [for (final s in d as List) SourceInfo.fromJson((s as Map).cast())]);

  Future<Map<String, dynamic>> health(String sourceId, {bool force = false}) =>
      client.get('/sources/$sourceId/health', query: {'force': force}, parse: (d) => (d as Map).cast());

  Future<MangaPage> browse(String sourceId, {int page = 1, CatalogFilters filters = const CatalogFilters(), CancelToken? cancel}) =>
      client.get('/manga/$sourceId',
          query: {...filters.toQuery(), 'page': page},
          cancel: cancel,
          parse: (d) {
            final m = (d as Map).cast<String, dynamic>();
            return MangaPage(
              items: [for (final c in m['items'] as List) MangaCard.fromJson((c as Map).cast())],
              page: m['page'] as int? ?? page,
              hasNext: m['has_next'] as bool? ?? false,
            );
          });

  Future<(List<HomeSection>, List<SourceFailure>)> home(String sourceId) =>
      client.get('/manga/$sourceId/feed/home', parse: (d) {
        final m = (d as Map).cast<String, dynamic>();
        return (
          [
            for (final s in m['sections'] as List)
              HomeSection(
                key: (s as Map)['key'] as String,
                title: s['title'] as String,
                items: [for (final c in s['items'] as List) MangaCard.fromJson((c as Map).cast())],
              ),
          ],
          [for (final e in m['errors'] as List? ?? const []) SourceFailure.fromJson((e as Map).cast())],
        );
      });

  Future<TitleData> title(String sourceId, String mangaId, {bool refresh = false}) =>
      client.get('/manga/$sourceId/$mangaId', query: {'refresh': refresh ? true : null}, parse: (d) {
        final m = (d as Map).cast<String, dynamic>();
        return TitleData(
          manga: MangaDetails.fromJson((m['manga'] as Map).cast()),
          chapters: [for (final c in m['chapters'] as List) Chapter.fromJson((c as Map).cast())],
        );
      });

  Future<List<PageRef>> pages(String sourceId, String chapterId, {int? width}) =>
      client.get('/chapters/$sourceId/$chapterId/pages', parse: (d) {
        final m = (d as Map).cast<String, dynamic>();
        return [
          for (final p in m['pages'] as List)
            PageRef(
              index: (p as Map)['index'] as int,
              url: ImageUrls.fix(width == null ? p['url'] as String : '${p['url']}?w=$width'),
            ),
        ];
      });

  Future<SearchResults> search({
    required String query,
    int page = 1,
    List<String>? sources,
    bool includeNsfw = false,
    CatalogFilters filters = const CatalogFilters(),
    CancelToken? cancel,
  }) =>
      client.get('/search',
          query: {
            ...filters.toQuery(),
            'q': query,
            'page': page,
            'sources': sources,
            'include_nsfw': includeNsfw,
          },
          cancel: cancel,
          parse: (d) => parseSearchResults((d as Map).cast<String, dynamic>(), page: page));

  Future<List<Map<String, dynamic>>> manifest(String sourceId, List<String> chapterIds) =>
      client.post('/downloads/manifest',
          body: {'source_id': sourceId, 'chapter_ids': chapterIds},
          parse: (d) => [for (final c in ((d as Map)['chapters'] as List)) (c as Map).cast<String, dynamic>()]);
}


/// Grouped global-search payload (`items[].sources[]`) → cards.
SearchResults parseSearchResults(Map<String, dynamic> m, {int page = 1}) {
  final items = <MangaCard>[];
  for (final raw in m['items'] as List) {
    final g = (raw as Map).cast<String, dynamic>();
    final hits = [
      for (final s in g['sources'] as List)
        MangaCard(
          sourceId: (s as Map)['source_id'] as String,
          id: s['id'] as String,
          title: s['title'] as String? ?? '',
          coverUrl: s['cover_url'] as String? ?? '',
          sourceName: s['source_name'] as String?,
        ),
    ];
    if (hits.isEmpty) continue;
    final first = hits.first;
    items.add(MangaCard(
      sourceId: first.sourceId,
      id: first.id,
      title: g['title'] as String? ?? first.title,
      coverUrl: g['cover_url'] as String? ?? first.coverUrl,
      kind: MangaKind.parse(g['type'] as String?),
      sourceName: first.sourceName,
      alsoIn: hits.skip(1).toList(),
    ));
  }
  return SearchResults(
    items: items,
    page: m['page'] as int? ?? page,
    hasNext: m['has_next'] as bool? ?? false,
    errors: [for (final e in m['errors'] as List? ?? const []) SourceFailure.fromJson((e as Map).cast())],
  );
}
