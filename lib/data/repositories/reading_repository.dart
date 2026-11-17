import 'package:uuid/uuid.dart';

import '../local/daos.dart';
import '../models/manga.dart';
import '../models/reading.dart';
import 'library_repository.dart';

/// Progress, reading sessions (history) and locally computed statistics.
class ReadingRepository {
  ReadingRepository({
    required this.progress,
    required this.history,
    required this.library,
    required this.titleCache,
    required this.onChanged,
  });

  final ProgressDao progress;
  final HistoryDao history;
  final LibraryRepository library;
  final TitleCacheDao titleCache;
  final void Function() onChanged;

  Future<Map<String, ChapterProgress>> progressFor(String sourceId, String mangaId) =>
      progress.forManga(sourceId, mangaId);

  Future<ChapterProgress?> lastRead(String sourceId, String mangaId) => progress.latestForManga(sourceId, mangaId);

  /// Called by the reader on page change (debounced) and on exit — written to
  /// SQLite immediately so it survives a crash or a killed process.
  Future<void> saveProgress({
    required MangaDetails manga,
    required Chapter chapter,
    required int pageIndex,
    required int pageCount,
    bool? completed,
  }) async {
    final isDone = completed ?? (pageCount > 0 && pageIndex >= pageCount - 1);
    await progress.save(ChapterProgress(
      sourceId: manga.sourceId,
      mangaId: manga.id,
      chapterId: chapter.id,
      chapterNumber: chapter.number,
      chapterTitle: chapter.title,
      pageIndex: pageIndex,
      pageCount: pageCount,
      completed: isDone,
      updatedAt: DateTime.now().toUtc(),
    ));
    await library.touchRead(manga.sourceId, manga.id, chapterNumber: chapter.number, completed: isDone);
    onChanged();
  }

  Future<void> markChapters(MangaDetails manga, List<Chapter> chapters, {required bool read}) async {
    await progress.setCompleted(manga.sourceId, manga.id, chapters, read);
    if (read && chapters.isNotEmpty) {
      final maxNum = chapters.map((c) => c.number ?? 0).reduce((a, b) => a > b ? a : b);
      await library.touchRead(manga.sourceId, manga.id, chapterNumber: maxNum, completed: true);
    }
    onChanged();
  }

  /// Starts a reading session; returns its id. The reader updates it via [endSession].
  String newSessionId() => const Uuid().v4();

  Future<void> endSession({
    required String id,
    required MangaDetails manga,
    required Chapter chapter,
    required DateTime startedAt,
    required int activeSeconds,
    required int pagesRead,
  }) async {
    if (activeSeconds < 3 && pagesRead == 0) return; // accidental open
    await history.upsert(HistoryItem(
      id: id,
      sourceId: manga.sourceId,
      mangaId: manga.id,
      mangaTitle: manga.title,
      coverUrl: manga.coverUrl,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterNumber: chapter.number,
      startedAt: startedAt.toUtc(),
      readAt: DateTime.now().toUtc(),
      durationSeconds: activeSeconds.clamp(0, 86400),
      pagesRead: pagesRead,
    ));
    onChanged();
  }

  Future<List<HistoryItem>> recentHistory({int limit = 100, int offset = 0}) => history.recent(limit: limit, offset: offset);

  Future<void> deleteHistory(String id) async {
    await history.delete(id);
    onChanged();
  }

  Future<void> clearHistory() async {
    await history.clear();
    onChanged();
  }

  /// "Continue reading": latest unfinished chapter per title.
  Future<List<ContinueItem>> continueReading({int limit = 15}) async {
    final latest = await progress.latestPerManga(limit: limit * 2);
    final recent = await history.recent(limit: 300);
    final meta = <String, HistoryItem>{};
    for (final h in recent) {
      meta.putIfAbsent('${h.sourceId}:${h.mangaId}', () => h);
    }
    final out = <ContinueItem>[];
    for (final p in latest) {
      final key = '${p.sourceId}:${p.mangaId}';
      final entry = await library.get(p.sourceId, p.mangaId);
      var title = entry?.title ?? meta[key]?.mangaTitle;
      var cover = entry?.coverUrl ?? meta[key]?.coverUrl ?? '';
      if (title == null || title.isEmpty) {
        final cached = await titleCache.get(p.sourceId, p.mangaId);
        title = cached?.$1.manga.title;
        cover = cached?.$1.manga.coverUrl ?? cover;
      }
      if (title == null) continue;
      out.add(ContinueItem(
        sourceId: p.sourceId,
        mangaId: p.mangaId,
        title: title,
        coverUrl: cover,
        chapterId: p.chapterId,
        chapterTitle: p.chapterTitle,
        fraction: p.completed ? 1 : p.fraction,
        updatedAt: p.updatedAt,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  Future<ReadingStats> stats({int days = 365}) async {
    final items = await history.all();
    final completed = await progress.completedCount();
    final lib = await library.all();
    final byStatus = <String, int>{};
    for (final e in lib) {
      byStatus[e.status.api] = (byStatus[e.status.api] ?? 0) + 1;
    }
    return computeStats(items, completedChapters: completed, byStatus: byStatus, days: days, now: DateTime.now());
  }
}

/// Pure function (unit-tested): aggregates sessions into stats and an activity calendar.
ReadingStats computeStats(
  List<HistoryItem> items, {
  required int completedChapters,
  required Map<String, int> byStatus,
  int days = 365,
  required DateTime now,
}) {
  DateTime dayOf(DateTime d) {
    final l = d.toLocal();
    return DateTime(l.year, l.month, l.day);
  }

  final chaptersPerDay = <DateTime, Set<String>>{};
  final secondsPerDay = <DateTime, int>{};
  final titles = <String>{};
  var total = 0;
  for (final h in items) {
    final d = dayOf(h.readAt);
    chaptersPerDay.putIfAbsent(d, () => <String>{}).add('${h.sourceId}:${h.chapterId}');
    secondsPerDay[d] = (secondsPerDay[d] ?? 0) + h.durationSeconds;
    titles.add('${h.sourceId}:${h.mangaId}');
    total += h.durationSeconds;
  }
  final today = dayOf(now);
  final activeDays = chaptersPerDay.keys.toSet();

  var longest = 0, run = 0;
  DateTime? prev;
  for (final d in activeDays.toList()..sort()) {
    run = (prev != null && d.difference(prev).inDays == 1) ? run + 1 : 1;
    if (run > longest) longest = run;
    prev = d;
  }
  var current = 0;
  var cursor = activeDays.contains(today) ? today : today.subtract(const Duration(days: 1));
  while (activeDays.contains(cursor)) {
    current++;
    cursor = DateTime(cursor.year, cursor.month, cursor.day - 1);
  }
  final since = today.subtract(Duration(days: days - 1));
  final activity = [
    for (final d in activeDays.toList()..sort())
      if (!d.isBefore(since)) DayActivity(d, chaptersPerDay[d]!.length, secondsPerDay[d] ?? 0),
  ];
  final distinctChapters = chaptersPerDay.values.expand((s) => s).toSet().length;
  return ReadingStats(
    chaptersRead: completedChapters > distinctChapters ? completedChapters : distinctChapters,
    titlesRead: titles.length,
    totalSeconds: total,
    libraryTotal: byStatus.values.fold(0, (a, b) => a + b),
    byStatus: byStatus,
    currentStreak: current,
    longestStreak: longest,
    activity: activity,
  );
}
