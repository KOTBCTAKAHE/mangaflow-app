import 'dart:convert';

import 'manga.dart';

enum LibraryStatus {
  reading('reading', 'Читаю'),
  planned('planned', 'Планирую'),
  completed('completed', 'Завершено'),
  onHold('on_hold', 'Отложено'),
  dropped('dropped', 'Брошено');

  const LibraryStatus(this.api, this.label);
  final String api;
  final String label;

  static LibraryStatus parse(String? v) =>
      values.firstWhere((s) => s.api == v, orElse: () => LibraryStatus.planned);
}

enum ReadingMode {
  vertical('vertical', 'Вертикальная лента'),
  pagedLtr('paged_ltr', 'Страницы слева направо'),
  pagedRtl('paged_rtl', 'Страницы справа налево (RTL)'),
  doublePage('double', 'Разворот (две страницы)');

  const ReadingMode(this.api, this.label);
  final String api;
  final String label;

  bool get isPaged => this != ReadingMode.vertical;
  bool get isRtl => this == ReadingMode.pagedRtl;

  static ReadingMode parse(String? v, {ReadingMode fallback = ReadingMode.vertical}) =>
      values.firstWhere((m) => m.api == v, orElse: () => fallback);

  /// Sensible default per format: webtoons scroll, Japanese manga reads RTL.
  static ReadingMode suggestedFor(MangaKind? kind) => switch (kind) {
        MangaKind.manhwa || MangaKind.manhua => ReadingMode.vertical,
        MangaKind.manga => ReadingMode.pagedRtl,
        _ => ReadingMode.vertical,
      };
}

class LibraryEntry {
  const LibraryEntry({
    required this.sourceId,
    required this.mangaId,
    required this.title,
    required this.updatedAt,
    required this.addedAt,
    this.coverUrl = '',
    this.status = LibraryStatus.planned,
    this.isFavorite = false,
    this.readerSettings = const {},
    this.totalChapters,
    this.lastChapterNumber,
    this.lastReadAt,
    this.deleted = false,
    this.collectionIds = const [],
    this.unreadUpdates = 0,
  });

  final String sourceId;
  final String mangaId;
  final String title;
  final String coverUrl;
  final LibraryStatus status;
  final bool isFavorite;
  final Map<String, dynamic> readerSettings;
  final int? totalChapters;
  final double? lastChapterNumber;
  final DateTime? lastReadAt;
  final DateTime addedAt;
  final DateTime updatedAt;
  final bool deleted;
  final List<String> collectionIds;
  final int unreadUpdates;

  String get key => '$sourceId:$mangaId';

  MangaCard toCard() => MangaCard(sourceId: sourceId, id: mangaId, title: title, coverUrl: coverUrl);

  LibraryEntry copyWith({
    String? title,
    String? coverUrl,
    LibraryStatus? status,
    bool? isFavorite,
    Map<String, dynamic>? readerSettings,
    int? totalChapters,
    double? lastChapterNumber,
    DateTime? lastReadAt,
    DateTime? updatedAt,
    bool? deleted,
    List<String>? collectionIds,
    int? unreadUpdates,
  }) =>
      LibraryEntry(
        sourceId: sourceId,
        mangaId: mangaId,
        title: title ?? this.title,
        coverUrl: coverUrl ?? this.coverUrl,
        status: status ?? this.status,
        isFavorite: isFavorite ?? this.isFavorite,
        readerSettings: readerSettings ?? this.readerSettings,
        totalChapters: totalChapters ?? this.totalChapters,
        lastChapterNumber: lastChapterNumber ?? this.lastChapterNumber,
        lastReadAt: lastReadAt ?? this.lastReadAt,
        addedAt: addedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
        collectionIds: collectionIds ?? this.collectionIds,
        unreadUpdates: unreadUpdates ?? this.unreadUpdates,
      );

  factory LibraryEntry.fromApi(Map<String, dynamic> j) => LibraryEntry(
        sourceId: j['source_id'] as String,
        mangaId: j['manga_id'] as String,
        title: j['title'] as String? ?? '',
        coverUrl: j['cover_url'] as String? ?? '',
        status: LibraryStatus.parse(j['status'] as String?),
        isFavorite: j['is_favorite'] as bool? ?? false,
        readerSettings: (j['reader_settings'] as Map?)?.cast<String, dynamic>() ?? const {},
        totalChapters: j['total_chapters'] as int?,
        lastChapterNumber: (j['last_chapter_number'] as num?)?.toDouble(),
        lastReadAt: DateTime.tryParse(j['last_read_at'] as String? ?? ''),
        addedAt: DateTime.tryParse(j['added_at'] as String? ?? '') ?? DateTime.now().toUtc(),
        updatedAt: DateTime.parse(j['updated_at'] as String),
        deleted: j['deleted'] as bool? ?? false,
        collectionIds: [for (final c in (j['collection_ids'] as List? ?? const [])) c as String],
        unreadUpdates: j['unread_updates'] as int? ?? 0,
      );

  Map<String, dynamic> toApi() => {
        'source_id': sourceId,
        'manga_id': mangaId,
        'title': title,
        'cover_url': coverUrl,
        'status': status.api,
        'is_favorite': isFavorite,
        'reader_settings': readerSettings,
        'total_chapters': totalChapters,
        'last_chapter_number': lastChapterNumber,
        'last_read_at': lastReadAt?.toUtc().toIso8601String(),
        'added_at': addedAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'deleted': deleted,
      };

  factory LibraryEntry.fromRow(Map<String, Object?> r, {List<String> collections = const []}) => LibraryEntry(
        sourceId: r['source_id']! as String,
        mangaId: r['manga_id']! as String,
        title: r['title']! as String,
        coverUrl: r['cover_url'] as String? ?? '',
        status: LibraryStatus.parse(r['status'] as String?),
        isFavorite: (r['is_favorite'] as int? ?? 0) == 1,
        readerSettings: r['reader_settings'] == null
            ? const {}
            : (jsonDecode(r['reader_settings']! as String) as Map).cast<String, dynamic>(),
        totalChapters: r['total_chapters'] as int?,
        lastChapterNumber: (r['last_chapter_number'] as num?)?.toDouble(),
        lastReadAt: _ms(r['last_read_at']),
        addedAt: _ms(r['added_at']) ?? DateTime.now().toUtc(),
        updatedAt: _ms(r['updated_at']) ?? DateTime.now().toUtc(),
        deleted: (r['deleted'] as int? ?? 0) == 1,
        collectionIds: collections,
        unreadUpdates: r['unread_updates'] as int? ?? 0,
      );

  Map<String, Object?> toRow({bool dirty = true}) => {
        'source_id': sourceId,
        'manga_id': mangaId,
        'title': title,
        'cover_url': coverUrl,
        'status': status.api,
        'is_favorite': isFavorite ? 1 : 0,
        'reader_settings': jsonEncode(readerSettings),
        'total_chapters': totalChapters,
        'last_chapter_number': lastChapterNumber,
        'last_read_at': lastReadAt?.millisecondsSinceEpoch,
        'added_at': addedAt.millisecondsSinceEpoch,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'deleted': deleted ? 1 : 0,
        'unread_updates': unreadUpdates,
        'dirty': dirty ? 1 : 0,
      };
}

DateTime? _ms(Object? v) => v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int, isUtc: true);

class Collection {
  const Collection({required this.id, required this.name, this.position = 0, this.entryKeys = const []});
  final String id;
  final String name;
  final int position;

  /// `source:manga` keys
  final List<String> entryKeys;
}
