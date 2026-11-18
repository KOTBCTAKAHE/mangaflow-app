import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/storage/database.dart';
import 'package:mangaflow/data/local/bookmarks_dao.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/data/models/reading.dart';
import 'package:mangaflow/data/services/cross_source.dart';
import 'package:mangaflow/data/services/year_review.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

HistoryItem h(String manga, String ch, DateTime at, {int sec = 300}) => HistoryItem(
      id: '$manga$ch$at', sourceId: 's', mangaId: manga, chapterId: ch, startedAt: at, readAt: at,
      mangaTitle: 'Title $manga', durationSeconds: sec);

void main() {
  test('year review: chapters, hours, top title, genres, binge day, streak, night share', () {
    final d = DateTime(2026, 3, 10, 21);
    final items = [
      for (var i = 0; i < 6; i++) h('a', 'a$i', d.add(Duration(minutes: i))), // binge: 6 on Mar 10
      h('a', 'a6', DateTime(2026, 3, 11, 2)), // night, streak day 2
      h('b', 'b1', DateTime(2026, 3, 12, 20)), // streak day 3
      h('b', 'b1', DateTime(2026, 3, 12, 21)), // re-read: counted once
      h('c', 'c1', DateTime(2025, 12, 31, 20)), // other year
    ];
    final r = computeYearReview(items, 2026, genresOf: (s, m) => m == 'a' ? ['Фэнтези', 'Боевик'] : ['Романтика']);
    expect(r.chapters, 8);
    expect(r.titles, 2);
    expect(r.topTitles.first.title, 'Title a');
    expect(r.topTitles.first.chapters, 7);
    expect(r.topGenres.first, 'Фэнтези');
    expect(r.bingeChapters, 6);
    expect(r.bingeDay, DateTime(2026, 3, 10));
    expect(r.longestStreak, 3);
    expect(r.busiestMonth, 3);
    expect(r.nightShare, closeTo(1 / 8, 1e-9));
    expect(r.seconds, 9 * 300);
    expect(computeYearReview(items, 2024).isEmpty, isTrue);
  });

  test('achievements unlock by progress', () {
    final stats = ReadingStats(chaptersRead: 120, titlesRead: 3, totalSeconds: 3600 * 5, libraryTotal: 2,
        byStatus: const {}, currentStreak: 2, longestStreak: 8, activity: const []);
    final list = computeAchievements(stats: stats, history: const [], library: const []);
    bool on(String id) => list.firstWhere((a) => a.id == id).unlocked;
    expect(on('first'), isTrue);
    expect(on('ch100'), isTrue);
    expect(on('ch1000'), isFalse);
    expect(on('streak7'), isTrue);
    expect(on('streak30'), isFalse);
    expect(list.firstWhere((a) => a.id == 'ch1000').fraction, closeTo(0.12, 1e-9));
    expect(LibraryStatus.values, isNotEmpty);
  });

  test('title normalisation for cross-source matching', () {
    expect(normalizeTitle('Поднятие уровня в одиночку!'), normalizeTitle('поднятие  уровня — в одиночку'));
    expect(normalizeTitle('Ёлка'), 'елка');
    expect(normalizeTitle('Solo Leveling: Ragnarok'), 'sololevelingragnarok');
  });

  test('bookmarks: v3 migration, put/edit/delete, per-chapter ids', () async {
    sqfliteFfiInit();
    final db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final dao = BookmarksDao(db.db);
    final id = Bookmark.idFor('s', 'c1', 4);
    await dao.put(Bookmark(id: id, sourceId: 's', mangaId: 'm', chapterId: 'c1', pageIndex: 4, createdAt: DateTime(2026), note: 'тут'));
    await dao.put(Bookmark(id: id, sourceId: 's', mangaId: 'm', chapterId: 'c1', pageIndex: 4, createdAt: DateTime(2026), note: 'правка'));
    expect((await dao.all()).single.note, 'правка');
    expect(await dao.idsForChapter('s', 'c1'), {id});
    expect((await dao.forManga('s', 'm')).length, 1);
    await dao.delete(id);
    expect(await dao.all(), isEmpty);
    await db.close();
  });
}
