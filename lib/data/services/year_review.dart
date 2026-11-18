import '../models/library.dart';
import '../models/reading.dart';

class TitleCount {
  const TitleCount(this.title, this.coverUrl, this.chapters);
  final String title;
  final String coverUrl;
  final int chapters;
}

/// "Итоги года" — Spotify-Wrapped-style summary.
class YearReview {
  const YearReview({
    required this.year,
    required this.chapters,
    required this.seconds,
    required this.titles,
    required this.activeDays,
    required this.longestStreak,
    this.topTitles = const [],
    this.topGenres = const [],
    this.bingeDay,
    this.bingeChapters = 0,
    this.busiestMonth,
    this.nightShare = 0,
  });

  final int year;
  final int chapters;
  final int seconds;
  final int titles;
  final int activeDays;
  final int longestStreak;
  final List<TitleCount> topTitles;
  final List<String> topGenres;

  /// The day with the most chapters ("самый долгий запой").
  final DateTime? bingeDay;
  final int bingeChapters;
  final int? busiestMonth; // 1..12
  /// Share of chapters read between 00:00 and 05:00.
  final double nightShare;

  bool get isEmpty => chapters == 0;
}

/// Pure function: history of one year → review. [genresOf] gives a title's genres.
YearReview computeYearReview(
  List<HistoryItem> history,
  int year, {
  List<String> Function(String sourceId, String mangaId)? genresOf,
}) {
  final items = [for (final h in history) if (h.readAt.toLocal().year == year) h];
  final chapters = <String>{};
  final perTitle = <String, Set<String>>{};
  final titleInfo = <String, (String, String)>{};
  final perDay = <DateTime, Set<String>>{};
  final perMonth = <int, int>{};
  var seconds = 0, night = 0;
  for (final h in items) {
    final l = h.readAt.toLocal();
    final ch = '${h.sourceId}:${h.chapterId}';
    final t = '${h.sourceId}:${h.mangaId}';
    if (chapters.add(ch)) {
      perMonth[l.month] = (perMonth[l.month] ?? 0) + 1;
      if (l.hour < 5) night++;
    }
    perTitle.putIfAbsent(t, () => {}).add(ch);
    titleInfo[t] = (h.mangaTitle, h.coverUrl);
    perDay.putIfAbsent(DateTime(l.year, l.month, l.day), () => {}).add(ch);
    seconds += h.durationSeconds;
  }
  final top = perTitle.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length));
  final genreCount = <String, int>{};
  if (genresOf != null) {
    for (final e in perTitle.entries) {
      final parts = e.key.split(':');
      for (final g in genresOf(parts.first, parts.sublist(1).join(':'))) {
        genreCount[g] = (genreCount[g] ?? 0) + e.value.length;
      }
    }
  }
  final genres = genreCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  DateTime? binge;
  var bingeN = 0;
  perDay.forEach((d, s) {
    if (s.length > bingeN) {
      bingeN = s.length;
      binge = d;
    }
  });
  var longest = 0, run = 0;
  DateTime? prev;
  for (final d in perDay.keys.toList()..sort()) {
    run = prev != null && d.difference(prev).inDays == 1 ? run + 1 : 1;
    if (run > longest) longest = run;
    prev = d;
  }
  int? month;
  perMonth.forEach((m, n) {
    if (month == null || n > perMonth[month]!) month = m;
  });
  return YearReview(
    year: year,
    chapters: chapters.length,
    seconds: seconds,
    titles: perTitle.length,
    activeDays: perDay.length,
    longestStreak: longest,
    topTitles: [for (final e in top.take(5)) TitleCount(titleInfo[e.key]!.$1, titleInfo[e.key]!.$2, e.value.length)],
    topGenres: [for (final g in genres.take(3)) g.key],
    bingeDay: binge,
    bingeChapters: bingeN,
    busiestMonth: month,
    nightShare: chapters.isEmpty ? 0 : night / chapters.length,
  );
}

class Achievement {
  const Achievement(this.id, this.title, this.description, {required this.progress, required this.goal});
  final String id;
  final String title;
  final String description;
  final int progress;
  final int goal;

  bool get unlocked => progress >= goal;
  double get fraction => goal == 0 ? 1 : (progress / goal).clamp(0.0, 1.0);
}

/// All achievements with progress, computed from local data.
List<Achievement> computeAchievements({
  required ReadingStats stats,
  required List<HistoryItem> history,
  required List<LibraryEntry> library,
}) {
  final perDay = <DateTime, Set<String>>{};
  var night = 0;
  final nightSeen = <String>{};
  final sources = <String>{};
  for (final h in history) {
    final l = h.readAt.toLocal();
    final ch = '${h.sourceId}:${h.chapterId}';
    perDay.putIfAbsent(DateTime(l.year, l.month, l.day), () => {}).add(ch);
    if (l.hour < 5 && nightSeen.add(ch)) night++;
    sources.add(h.sourceId);
  }
  final binge = perDay.values.fold<int>(0, (m, s) => s.length > m ? s.length : m);
  final completed = library.where((e) => e.status == LibraryStatus.completed).length;
  final hours = stats.totalSeconds ~/ 3600;
  final best = stats.longestStreak;
  return [
    Achievement('first', 'Первая глава', 'Прочитать первую главу', progress: stats.chaptersRead, goal: 1),
    Achievement('ch100', 'Книжный червь', 'Прочитать 100 глав', progress: stats.chaptersRead, goal: 100),
    Achievement('ch1000', 'Марафонец', 'Прочитать 1000 глав', progress: stats.chaptersRead, goal: 1000),
    Achievement('ch5000', 'Легенда', 'Прочитать 5000 глав', progress: stats.chaptersRead, goal: 5000),
    Achievement('streak7', 'Неделя подряд', 'Читать 7 дней подряд', progress: best, goal: 7),
    Achievement('streak30', 'Месяц без пропусков', 'Читать 30 дней подряд', progress: best, goal: 30),
    Achievement('streak100', 'Железная воля', 'Читать 100 дней подряд', progress: best, goal: 100),
    Achievement('binge', 'Запой', '50 глав за один день', progress: binge, goal: 50),
    Achievement('owl', 'Сова', '20 глав между полуночью и пятью утра', progress: night, goal: 20),
    Achievement('hours', 'Сто часов', '100 часов чтения', progress: hours, goal: 100),
    Achievement('finisher', 'Дочитыватель', 'Завершить 10 тайтлов', progress: completed, goal: 10),
    Achievement('collector', 'Коллекционер', '50 тайтлов в библиотеке', progress: library.length, goal: 50),
    Achievement('explorer', 'Исследователь', 'Читать в 3 разных источниках', progress: sources.length, goal: 3),
  ];
}
