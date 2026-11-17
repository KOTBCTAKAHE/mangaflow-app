import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/core/storage/database.dart';
import 'package:mangaflow/data/local/daos.dart';
import 'package:mangaflow/data/models/library.dart';
import 'package:mangaflow/data/models/manga.dart';
import 'package:mangaflow/data/models/reading.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late AppDatabase db;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    db = await AppDatabase.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
  });

  tearDown(() => db.close());

  LibraryEntry entry({DateTime? updated, LibraryStatus status = LibraryStatus.planned}) => LibraryEntry(
        sourceId: 'mangalib',
        mangaId: 'op',
        title: 'Ван Пис',
        status: status,
        addedAt: DateTime.utc(2026),
        updatedAt: updated ?? DateTime.utc(2026, 1, 2),
      );

  test('library: unsynced local edits win over older remote copies', () async {
    final dao = LibraryDao(db.db);
    await dao.upsert(entry(status: LibraryStatus.reading, updated: DateTime.utc(2026, 3)));
    await dao.mergeRemote(entry(status: LibraryStatus.dropped, updated: DateTime.utc(2026, 2)));
    expect((await dao.get('mangalib', 'op'))!.status, LibraryStatus.reading);

    await dao.mergeRemote(entry(status: LibraryStatus.completed, updated: DateTime.utc(2026, 4)));
    expect((await dao.get('mangalib', 'op'))!.status, LibraryStatus.completed);
    expect(await dao.dirty(), isEmpty); // remote copy is clean
  });

  test('library: markClean keeps rows edited after the push dirty', () async {
    final dao = LibraryDao(db.db);
    final pushed = entry(updated: DateTime.utc(2026, 1, 1));
    await dao.upsert(pushed);
    await dao.upsert(entry(updated: DateTime.utc(2026, 1, 5), status: LibraryStatus.reading)); // edited meanwhile
    await dao.markClean([pushed]);
    expect(await dao.dirty(), hasLength(1));
  });

  test('progress: completion is monotonic and latest-per-manga works', () async {
    final dao = ProgressDao(db.db);
    ChapterProgress p(String ch, int page, {bool done = false, required DateTime at}) => ChapterProgress(
        sourceId: 's', mangaId: 'm', chapterId: ch, pageIndex: page, pageCount: 20, completed: done, updatedAt: at);
    await dao.save(p('c1', 19, done: true, at: DateTime.utc(2026, 1, 1)));
    await dao.save(p('c1', 0, at: DateTime.utc(2026, 1, 2)));
    expect((await dao.get('s', 'm', 'c1'))!.completed, isTrue);

    await dao.save(p('c2', 5, at: DateTime.utc(2026, 1, 3)));
    final latest = await dao.latestPerManga();
    expect(latest.single.chapterId, 'c2');
    expect(await dao.completedCount(), 1);

    await dao.setCompleted('s', 'm', [const Chapter(id: 'c3', title: 'Глава 3', number: 3)], true);
    expect(await dao.completedCount(), 2);
  });

  test('title cache round-trip for offline browsing', () async {
    final dao = TitleCacheDao(db.db);
    const data = TitleData(
      manga: MangaDetails(sourceId: 's', sourceName: 'S', id: 'm', title: 'Берсерк', genres: ['Драма'], status: PubStatus.ongoing),
      chapters: [Chapter(id: 'c2', title: 'Глава 2', number: 2), Chapter(id: 'c1', title: 'Глава 1', number: 1)],
    );
    await dao.put(data);
    final (cached, _) = (await dao.get('s', 'm'))!;
    expect(cached.fromCache, isTrue);
    expect(cached.manga.title, 'Берсерк');
    expect(cached.manga.status, PubStatus.ongoing);
    expect(cached.chapters.map((c) => c.id), ['c2', 'c1']);
  });

  test('search history keeps recent unique queries', () async {
    final dao = SearchHistoryDao(db.db);
    await dao.add('берсерк');
    await dao.add('ван пис');
    await dao.add('берсерк');
    expect(await dao.recent(), ['берсерк', 'ван пис']);
  });

  test('collections membership', () async {
    final lib = LibraryDao(db.db);
    final cols = CollectionsDao(db.db);
    await lib.upsert(entry());
    final id = await cols.create('Сёнэн');
    await cols.setMembership('mangalib', 'op', {id});
    expect((await lib.get('mangalib', 'op'))!.collectionIds, [id]);
    expect((await cols.all()).single.entryKeys, ['mangalib:op']);
    await cols.delete(id);
    expect((await lib.get('mangalib', 'op'))!.collectionIds, isEmpty);
  });

  test('updates: only new ones are reported', () async {
    final dao = UpdatesDao(db.db);
    ChapterUpdate u(String id) => ChapterUpdate(
        id: id, sourceId: 's', mangaId: 'm', mangaTitle: 'T', coverUrl: '', chapterId: id, chapterTitle: id,
        detectedAt: DateTime.utc(2026));
    expect(await dao.addAll([u('a'), u('b')]), hasLength(2));
    expect(await dao.addAll([u('b'), u('c')]), hasLength(1));
    expect(await dao.unseenCount(), 3);
    await dao.markSeen();
    expect(await dao.unseenCount(), 0);
  });
}
