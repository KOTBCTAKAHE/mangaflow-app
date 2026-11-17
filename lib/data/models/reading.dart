class ChapterProgress {
  const ChapterProgress({
    required this.sourceId,
    required this.mangaId,
    required this.chapterId,
    required this.updatedAt,
    this.chapterNumber,
    this.chapterTitle = '',
    this.pageIndex = 0,
    this.pageCount = 0,
    this.completed = false,
  });

  final String sourceId;
  final String mangaId;
  final String chapterId;
  final double? chapterNumber;
  final String chapterTitle;
  final int pageIndex;
  final int pageCount;
  final bool completed;
  final DateTime updatedAt;

  double get fraction => pageCount <= 0 ? (completed ? 1 : 0) : ((pageIndex + 1) / pageCount).clamp(0, 1);

  factory ChapterProgress.fromApi(Map<String, dynamic> j) => ChapterProgress(
        sourceId: j['source_id'] as String,
        mangaId: j['manga_id'] as String,
        chapterId: j['chapter_id'] as String,
        chapterNumber: (j['chapter_number'] as num?)?.toDouble(),
        chapterTitle: j['chapter_title'] as String? ?? '',
        pageIndex: j['page_index'] as int? ?? 0,
        pageCount: j['page_count'] as int? ?? 0,
        completed: j['completed'] as bool? ?? false,
        updatedAt: DateTime.parse(j['updated_at'] as String),
      );

  Map<String, dynamic> toApi() => {
        'source_id': sourceId,
        'manga_id': mangaId,
        'chapter_id': chapterId,
        'chapter_number': chapterNumber,
        'chapter_title': chapterTitle,
        'page_index': pageIndex,
        'page_count': pageCount,
        'completed': completed,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };

  factory ChapterProgress.fromRow(Map<String, Object?> r) => ChapterProgress(
        sourceId: r['source_id']! as String,
        mangaId: r['manga_id']! as String,
        chapterId: r['chapter_id']! as String,
        chapterNumber: (r['chapter_number'] as num?)?.toDouble(),
        chapterTitle: r['chapter_title'] as String? ?? '',
        pageIndex: r['page_index'] as int? ?? 0,
        pageCount: r['page_count'] as int? ?? 0,
        completed: (r['completed'] as int? ?? 0) == 1,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at']! as int, isUtc: true),
      );

  Map<String, Object?> toRow({bool dirty = true}) => {
        'source_id': sourceId,
        'manga_id': mangaId,
        'chapter_id': chapterId,
        'chapter_number': chapterNumber,
        'chapter_title': chapterTitle,
        'page_index': pageIndex,
        'page_count': pageCount,
        'completed': completed ? 1 : 0,
        'updated_at': updatedAt.millisecondsSinceEpoch,
        'dirty': dirty ? 1 : 0,
      };
}

class HistoryItem {
  const HistoryItem({
    required this.id,
    required this.sourceId,
    required this.mangaId,
    required this.chapterId,
    required this.startedAt,
    required this.readAt,
    this.mangaTitle = '',
    this.coverUrl = '',
    this.chapterTitle = '',
    this.chapterNumber,
    this.durationSeconds = 0,
    this.pagesRead = 0,
  });

  final String id;
  final String sourceId;
  final String mangaId;
  final String mangaTitle;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final double? chapterNumber;
  final DateTime startedAt;
  final DateTime readAt;
  final int durationSeconds;
  final int pagesRead;

  factory HistoryItem.fromApi(Map<String, dynamic> j) => HistoryItem(
        id: j['id'] as String,
        sourceId: j['source_id'] as String,
        mangaId: j['manga_id'] as String,
        mangaTitle: j['manga_title'] as String? ?? '',
        coverUrl: j['cover_url'] as String? ?? '',
        chapterId: j['chapter_id'] as String,
        chapterTitle: j['chapter_title'] as String? ?? '',
        chapterNumber: (j['chapter_number'] as num?)?.toDouble(),
        startedAt: DateTime.parse(j['started_at'] as String),
        readAt: DateTime.parse(j['read_at'] as String),
        durationSeconds: j['duration_seconds'] as int? ?? 0,
        pagesRead: j['pages_read'] as int? ?? 0,
      );

  Map<String, dynamic> toApi() => {
        'id': id,
        'source_id': sourceId,
        'manga_id': mangaId,
        'manga_title': mangaTitle,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_number': chapterNumber,
        'started_at': startedAt.toUtc().toIso8601String(),
        'read_at': readAt.toUtc().toIso8601String(),
        'duration_seconds': durationSeconds.clamp(0, 86400),
        'pages_read': pagesRead,
      };

  factory HistoryItem.fromRow(Map<String, Object?> r) => HistoryItem(
        id: r['id']! as String,
        sourceId: r['source_id']! as String,
        mangaId: r['manga_id']! as String,
        mangaTitle: r['manga_title'] as String? ?? '',
        coverUrl: r['cover_url'] as String? ?? '',
        chapterId: r['chapter_id']! as String,
        chapterTitle: r['chapter_title'] as String? ?? '',
        chapterNumber: (r['chapter_number'] as num?)?.toDouble(),
        startedAt: DateTime.fromMillisecondsSinceEpoch(r['started_at']! as int, isUtc: true),
        readAt: DateTime.fromMillisecondsSinceEpoch(r['read_at']! as int, isUtc: true),
        durationSeconds: r['duration_seconds'] as int? ?? 0,
        pagesRead: r['pages_read'] as int? ?? 0,
      );

  Map<String, Object?> toRow({bool dirty = true}) => {
        'id': id,
        'source_id': sourceId,
        'manga_id': mangaId,
        'manga_title': mangaTitle,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_number': chapterNumber,
        'started_at': startedAt.millisecondsSinceEpoch,
        'read_at': readAt.millisecondsSinceEpoch,
        'duration_seconds': durationSeconds,
        'pages_read': pagesRead,
        'dirty': dirty ? 1 : 0,
      };
}

class ChapterUpdate {
  const ChapterUpdate({
    required this.id,
    required this.sourceId,
    required this.mangaId,
    required this.mangaTitle,
    required this.coverUrl,
    required this.chapterId,
    required this.chapterTitle,
    required this.detectedAt,
    this.chapterNumber,
    this.seen = false,
  });

  final String id;
  final String sourceId;
  final String mangaId;
  final String mangaTitle;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final double? chapterNumber;
  final DateTime detectedAt;
  final bool seen;

  factory ChapterUpdate.fromApi(Map<String, dynamic> j) => ChapterUpdate(
        id: j['id'] as String,
        sourceId: j['source_id'] as String,
        mangaId: j['manga_id'] as String,
        mangaTitle: j['manga_title'] as String? ?? '',
        coverUrl: j['cover_url'] as String? ?? '',
        chapterId: j['chapter_id'] as String,
        chapterTitle: j['chapter_title'] as String? ?? '',
        chapterNumber: (j['chapter_number'] as num?)?.toDouble(),
        detectedAt: DateTime.parse(j['detected_at'] as String),
        seen: j['seen'] as bool? ?? false,
      );
}

class DayActivity {
  const DayActivity(this.day, this.chapters, this.seconds);
  final DateTime day;
  final int chapters;
  final int seconds;
}

class ReadingStats {
  const ReadingStats({
    required this.chaptersRead,
    required this.titlesRead,
    required this.totalSeconds,
    required this.libraryTotal,
    required this.byStatus,
    required this.currentStreak,
    required this.longestStreak,
    required this.activity,
  });

  final int chaptersRead;
  final int titlesRead;
  final int totalSeconds;
  final int libraryTotal;
  final Map<String, int> byStatus;
  final int currentStreak;
  final int longestStreak;
  final List<DayActivity> activity;
}

class ContinueItem {
  const ContinueItem({
    required this.sourceId,
    required this.mangaId,
    required this.title,
    required this.coverUrl,
    required this.chapterId,
    required this.chapterTitle,
    required this.fraction,
    required this.updatedAt,
  });

  final String sourceId;
  final String mangaId;
  final String title;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final double fraction;
  final DateTime updatedAt;
}
