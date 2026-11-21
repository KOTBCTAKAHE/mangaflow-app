/// Catalog models mirroring backend `/api/v1` schemas.
library;

enum MangaKind {
  manga('manga', 'Манга'),
  manhwa('manhwa', 'Манхва'),
  manhua('manhua', 'Маньхуа'),
  comic('comic', 'Комикс'),
  other('other', 'Другое');

  const MangaKind(this.api, this.label);
  final String api;
  final String label;

  static MangaKind? parse(String? v) {
    for (final k in values) {
      if (k.api == v) return k;
    }
    return null;
  }
}

enum PubStatus {
  ongoing('ongoing', 'Выходит'),
  completed('completed', 'Завершён'),
  hiatus('hiatus', 'Приостановлен'),
  cancelled('cancelled', 'Прекращён'),
  announced('announced', 'Анонс'),
  unknown('unknown', 'Неизвестно');

  const PubStatus(this.api, this.label);
  final String api;
  final String label;

  static PubStatus parse(String? v) =>
      values.firstWhere((s) => s.api == v, orElse: () => PubStatus.unknown);
}

enum SortMode {
  popular('popular', 'Популярное'),
  rating('rating', 'По рейтингу'),
  updated('updated', 'Обновлённое'),
  created('created', 'Новое'),
  name('name', 'По названию');

  const SortMode(this.api, this.label);
  final String api;
  final String label;

  static SortMode parse(String? v) => values.firstWhere((s) => s.api == v, orElse: () => SortMode.popular);
}

class Genre {
  const Genre(this.id, this.name);
  final String id;
  final String name;

  factory Genre.fromJson(Map<String, dynamic> j) => Genre(j['id'] as String, j['name'] as String);
}

class SourceCaps {
  const SourceCaps({
    this.search = true,
    this.genreFilter = false,
    this.genreExclude = false,
    this.typeFilter = false,
    this.statusFilter = false,
    this.sortOrders = const [SortMode.popular, SortMode.updated],
  });

  final bool search;
  final bool genreFilter;
  final bool genreExclude;
  final bool typeFilter;
  final bool statusFilter;
  final List<SortMode> sortOrders;

  factory SourceCaps.fromJson(Map<String, dynamic> j) => SourceCaps(
        search: j['search'] as bool? ?? true,
        genreFilter: j['genre_filter'] as bool? ?? false,
        genreExclude: j['genre_exclude'] as bool? ?? false,
        typeFilter: j['type_filter'] as bool? ?? false,
        statusFilter: j['status_filter'] as bool? ?? false,
        sortOrders: [for (final s in (j['sort_orders'] as List? ?? const [])) SortMode.parse(s as String)],
      );
}

class SourceInfo {
  const SourceInfo({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.isNsfw = false,
    this.notes = '',
    this.caps = const SourceCaps(),
    this.genres = const [],
    this.lang = 'ru',
  });

  final String id;
  final String name;
  final String baseUrl;

  /// Translation language of the catalog (`ru`, `en`, …).
  final String lang;

  /// Short label for non-Russian catalogs ("EN"); null for Russian ones.
  String? get langBadge => lang == 'ru' ? null : lang.toUpperCase();
  final bool isNsfw;
  final String notes;
  final SourceCaps caps;
  final List<Genre> genres;

  factory SourceInfo.fromJson(Map<String, dynamic> j) => SourceInfo(
        id: j['id'] as String,
        name: j['name'] as String,
        baseUrl: j['base_url'] as String? ?? '',
        isNsfw: j['is_nsfw'] as bool? ?? false,
        lang: j['lang'] as String? ?? 'ru',
        notes: j['notes'] as String? ?? '',
        caps: SourceCaps.fromJson((j['capabilities'] as Map?)?.cast<String, dynamic>() ?? const {}),
        genres: [for (final g in (j['genres'] as List? ?? const [])) Genre.fromJson((g as Map).cast())],
      );
}

/// Lightweight card used in carousels, grids and search results.
class MangaCard {
  const MangaCard({
    required this.sourceId,
    required this.id,
    required this.title,
    this.coverUrl = '',
    this.kind,
    this.sourceName,
    this.alsoIn = const [],
  });

  final String sourceId;
  final String id;
  final String title;
  final String coverUrl;
  final MangaKind? kind;
  final String? sourceName;

  /// Other sources that have the same title (global search merge).
  final List<MangaCard> alsoIn;

  String get key => '$sourceId:$id';

  factory MangaCard.fromJson(Map<String, dynamic> j) => MangaCard(
        sourceId: j['source_id'] as String,
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        coverUrl: j['cover_url'] as String? ?? '',
        kind: MangaKind.parse(j['type'] as String?),
        sourceName: j['source_name'] as String?,
      );
}

class MangaPage {
  const MangaPage({required this.items, required this.page, required this.hasNext});
  final List<MangaCard> items;
  final int page;
  final bool hasNext;
}

class SourceFailure {
  const SourceFailure(this.sourceId, this.code, this.message);
  final String sourceId;
  final String code;
  final String message;

  factory SourceFailure.fromJson(Map<String, dynamic> j) =>
      SourceFailure(j['source_id'] as String, j['code'] as String, j['message'] as String? ?? '');
}

class SearchResults {
  const SearchResults({required this.items, required this.hasNext, required this.page, this.errors = const []});
  final List<MangaCard> items;
  final bool hasNext;
  final int page;
  final List<SourceFailure> errors;
}

class Chapter {
  const Chapter({
    required this.id,
    required this.title,
    this.number,
    this.volume,
    this.uploadedAt,
    this.scanlator,
    this.sourceName,
    this.alts = const [],
  });

  /// `@<source>:<id>` for a chapter that only another source has (one title, every source).
  final String id;
  final String title;
  final double? number;
  final String? volume;
  final DateTime? uploadedAt;
  final String? scanlator;

  /// Merged titles: the site the chapter is read from.
  final String? sourceName;

  /// The same chapter on other sources: read from there when this one fails.
  final List<ChapterAlt> alts;

  bool get isForeign => id.startsWith('@');

  factory Chapter.fromJson(Map<String, dynamic> j) => Chapter(
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        number: (j['number'] as num?)?.toDouble(),
        volume: j['volume'] as String?,
        uploadedAt: DateTime.tryParse(j['uploaded_at'] as String? ?? ''),
        scanlator: j['scanlator'] as String?,
        sourceName: j['source_name'] as String?,
        alts: [
          for (final a in (j['alts'] as List?) ?? const [])
            ChapterAlt((a as Map)['source_id'] as String, a['chapter_id'] as String),
        ],
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'number': number,
        'volume': volume,
        'uploaded_at': uploadedAt?.toIso8601String(),
        'scanlator': scanlator,
        if (sourceName != null) 'source_name': sourceName,
        if (alts.isNotEmpty) 'alts': [for (final a in alts) {'source_id': a.sourceId, 'chapter_id': a.chapterId}],
      };
}

/// The same chapter on another source.
class ChapterAlt {
  const ChapterAlt(this.sourceId, this.chapterId);
  final String sourceId;
  final String chapterId;
}

/// A source that has the title too (merged titles).
class LinkedSource {
  const LinkedSource({required this.sourceId, required this.sourceName, required this.mangaId,
      required this.chaptersCount, this.latest, this.added = 0});
  final String sourceId;
  final String sourceName;
  final String mangaId;
  final int chaptersCount;
  final double? latest;

  /// Chapters this source added that the title's own source does not have.
  final int added;

  factory LinkedSource.fromJson(Map<String, dynamic> j) => LinkedSource(
        sourceId: j['source_id'] as String,
        sourceName: j['source_name'] as String? ?? j['source_id'] as String,
        mangaId: j['manga_id'] as String,
        chaptersCount: (j['chapters_count'] as num?)?.toInt() ?? 0,
        latest: (j['latest'] as num?)?.toDouble(),
        added: (j['added'] as num?)?.toInt() ?? 0,
      );
}

class MangaDetails {
  const MangaDetails({
    required this.sourceId,
    required this.sourceName,
    required this.id,
    required this.title,
    this.altTitles = const [],
    this.coverUrl = '',
    this.description = '',
    this.genres = const [],
    this.authors = const [],
    this.artists = const [],
    this.status = PubStatus.unknown,
    this.kind,
    this.webUrl = '',
    this.ageRating,
  });

  final String sourceId;
  final String sourceName;
  final String id;
  final String title;
  final List<String> altTitles;
  final String coverUrl;
  final String description;
  final List<String> genres;
  final List<String> authors;
  final List<String> artists;
  final PubStatus status;
  final MangaKind? kind;
  final String webUrl;
  final String? ageRating;

  static List<String> _strs(Object? v) => [for (final x in (v as List? ?? const [])) x as String];

  factory MangaDetails.fromJson(Map<String, dynamic> j) => MangaDetails(
        sourceId: j['source_id'] as String,
        sourceName: j['source_name'] as String? ?? j['source_id'] as String,
        id: j['id'] as String,
        title: j['title'] as String? ?? '',
        altTitles: _strs(j['alt_titles']),
        coverUrl: j['cover_url'] as String? ?? '',
        description: j['description'] as String? ?? '',
        genres: _strs(j['genres']),
        authors: _strs(j['authors']),
        artists: _strs(j['artists']),
        status: PubStatus.parse(j['status'] as String?),
        kind: MangaKind.parse(j['type'] as String?),
        webUrl: j['web_url'] as String? ?? '',
        ageRating: j['age_rating'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'source_id': sourceId,
        'source_name': sourceName,
        'id': id,
        'title': title,
        'alt_titles': altTitles,
        'cover_url': coverUrl,
        'description': description,
        'genres': genres,
        'authors': authors,
        'artists': artists,
        'status': status.api,
        'type': kind?.api,
        'web_url': webUrl,
        'age_rating': ageRating,
      };

  MangaCard toCard() => MangaCard(sourceId: sourceId, id: id, title: title, coverUrl: coverUrl, kind: kind);
}

class TitleData {
  const TitleData({required this.manga, required this.chapters, this.fromCache = false, this.sources = const []});
  final MangaDetails manga;

  /// Merged titles: every source the chapters come from (the title's own first).
  final List<LinkedSource> sources;

  bool get isMerged => sources.length > 1;

  /// Newest first (as returned by sources).
  final List<Chapter> chapters;

  /// True when served from the local offline cache.
  final bool fromCache;
}

class PageRef {
  const PageRef({required this.index, required this.url, this.localPath, this.key});
  final int index;
  final String url;

  /// Stable identity (`source/chapter/index`) — signed URLs change daily, this does not.
  final String? key;

  String get stableKey => key ?? localPath ?? url;

  PageRef withKey(String k) => PageRef(index: index, url: url, localPath: localPath, key: k);

  /// Set when the page is available on disk (downloaded chapter).
  final String? localPath;
}

class HomeSection {
  const HomeSection({required this.key, required this.title, required this.items});
  final String key;
  final String title;
  final List<MangaCard> items;
}
