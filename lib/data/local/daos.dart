import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/library.dart';
import '../models/manga.dart';
import '../models/reading.dart';

int _now() => DateTime.now().toUtc().millisecondsSinceEpoch;

class LibraryDao {
  LibraryDao(this.db);
  final Database db;

  Future<Map<String, List<String>>> _collections() async {
    final rows = await db.query('collection_items');
    final out = <String, List<String>>{};
    for (final r in rows) {
      out.putIfAbsent('${r['source_id']}:${r['manga_id']}', () => []).add(r['collection_id']! as String);
    }
    return out;
  }

  Future<List<LibraryEntry>> all({bool includeDeleted = false}) async {
    final rows = await db.query('library',
        where: includeDeleted ? null : 'deleted = 0', orderBy: 'COALESCE(last_read_at, updated_at) DESC');
    final cols = await _collections();
    return [for (final r in rows) LibraryEntry.fromRow(r, collections: cols['${r['source_id']}:${r['manga_id']}'] ?? const [])];
  }

  Future<LibraryEntry?> get(String sourceId, String mangaId) async {
    final rows = await db.query('library',
        where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId], limit: 1);
    if (rows.isEmpty) return null;
    final cols = await db.query('collection_items',
        columns: ['collection_id'], where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);
    return LibraryEntry.fromRow(rows.first, collections: [for (final c in cols) c['collection_id']! as String]);
  }

  Future<void> upsert(LibraryEntry e, {bool dirty = true}) =>
      db.insert('library', e.toRow(dirty: dirty), conflictAlgorithm: ConflictAlgorithm.replace);

  /// Applies a server copy unless the local copy is newer and still unsynced.
  Future<void> mergeRemote(LibraryEntry remote) async {
    final local = await get(remote.sourceId, remote.mangaId);
    if (local != null) {
      final row = await db.query('library',
          columns: ['dirty'], where: 'source_id = ? AND manga_id = ?', whereArgs: [remote.sourceId, remote.mangaId]);
      final dirty = (row.first['dirty'] as int? ?? 0) == 1;
      if (dirty && !local.updatedAt.isBefore(remote.updatedAt)) return;
    }
    await upsert(remote, dirty: false);
  }

  Future<List<LibraryEntry>> dirty() async {
    final rows = await db.query('library', where: 'dirty = 1');
    return [for (final r in rows) LibraryEntry.fromRow(r)];
  }

  Future<void> markClean(Iterable<LibraryEntry> items) async {
    final batch = db.batch();
    for (final e in items) {
      batch.update('library', {'dirty': 0},
          where: 'source_id = ? AND manga_id = ? AND updated_at <= ?',
          whereArgs: [e.sourceId, e.mangaId, e.updatedAt.millisecondsSinceEpoch]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> setUnread(String sourceId, String mangaId, int count) => db.update(
      'library', {'unread_updates': count}, where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);
}

class CollectionsDao {
  CollectionsDao(this.db);
  final Database db;

  Future<List<Collection>> all() async {
    final cols = await db.query('collections', orderBy: 'position, name');
    final items = await db.query('collection_items');
    return [
      for (final c in cols)
        Collection(
          id: c['id']! as String,
          name: c['name']! as String,
          position: c['position'] as int? ?? 0,
          entryKeys: [
            for (final i in items)
              if (i['collection_id'] == c['id']) '${i['source_id']}:${i['manga_id']}',
          ],
        ),
    ];
  }

  Future<String> create(String name, {String? remoteId}) async {
    final id = remoteId ?? const Uuid().v4();
    final pos = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM collections')) ?? 0;
    await db.insert('collections', {'id': id, 'name': name, 'position': pos, 'remote_id': remoteId},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  Future<void> rename(String id, String name) => db.update('collections', {'name': name}, where: 'id = ?', whereArgs: [id]);

  Future<void> delete(String id) => db.delete('collections', where: 'id = ?', whereArgs: [id]);

  Future<void> setMembership(String sourceId, String mangaId, Set<String> collectionIds) async {
    await db.transaction((txn) async {
      await txn.delete('collection_items', where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);
      for (final c in collectionIds) {
        await txn.insert('collection_items', {'collection_id': c, 'source_id': sourceId, 'manga_id': mangaId});
      }
    });
  }

  Future<String?> remoteId(String id) async {
    final r = await db.query('collections', columns: ['remote_id'], where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : r.first['remote_id'] as String?;
  }

  Future<void> setRemoteId(String id, String remoteId) =>
      db.update('collections', {'remote_id': remoteId}, where: 'id = ?', whereArgs: [id]);
}

class ProgressDao {
  ProgressDao(this.db);
  final Database db;

  Future<ChapterProgress?> get(String sourceId, String mangaId, String chapterId) async {
    final rows = await db.query('progress',
        where: 'source_id = ? AND manga_id = ? AND chapter_id = ?', whereArgs: [sourceId, mangaId, chapterId]);
    return rows.isEmpty ? null : ChapterProgress.fromRow(rows.first);
  }

  Future<Map<String, ChapterProgress>> forManga(String sourceId, String mangaId) async {
    final rows = await db.query('progress', where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);
    return {for (final r in rows) r['chapter_id']! as String: ChapterProgress.fromRow(r)};
  }

  Future<ChapterProgress?> latestForManga(String sourceId, String mangaId) async {
    final rows = await db.query('progress',
        where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId], orderBy: 'updated_at DESC', limit: 1);
    return rows.isEmpty ? null : ChapterProgress.fromRow(rows.first);
  }

  /// Latest progress row per title, newest first.
  Future<List<ChapterProgress>> latestPerManga({int limit = 20}) async {
    final rows = await db.rawQuery('''
      SELECT p.* FROM progress p
      JOIN (SELECT source_id, manga_id, MAX(updated_at) AS mx FROM progress GROUP BY source_id, manga_id) t
        ON p.source_id = t.source_id AND p.manga_id = t.manga_id AND p.updated_at = t.mx
      ORDER BY p.updated_at DESC LIMIT ?''', [limit]);
    return [for (final r in rows) ChapterProgress.fromRow(r)];
  }

  /// Saves progress; a chapter once completed stays completed.
  Future<void> save(ChapterProgress p, {bool dirty = true}) async {
    final existing = await get(p.sourceId, p.mangaId, p.chapterId);
    final completed = p.completed || (existing?.completed ?? false);
    final row = p.toRow(dirty: dirty)..['completed'] = completed ? 1 : 0;
    await db.insert('progress', row, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> mergeRemote(ChapterProgress remote) async {
    final local = await get(remote.sourceId, remote.mangaId, remote.chapterId);
    if (local != null && local.updatedAt.isAfter(remote.updatedAt)) {
      if (remote.completed && !local.completed) {
        await save(ChapterProgress(
            sourceId: local.sourceId, mangaId: local.mangaId, chapterId: local.chapterId, chapterNumber: local.chapterNumber,
            chapterTitle: local.chapterTitle, pageIndex: local.pageIndex, pageCount: local.pageCount, completed: true,
            updatedAt: local.updatedAt));
      }
      return;
    }
    await save(remote, dirty: false);
  }

  Future<void> setCompleted(String sourceId, String mangaId, List<Chapter> chapters, bool completed) async {
    final now = DateTime.now().toUtc();
    final batch = db.batch();
    for (final c in chapters) {
      batch.insert(
        'progress',
        ChapterProgress(
          sourceId: sourceId, mangaId: mangaId, chapterId: c.id, chapterNumber: c.number, chapterTitle: c.title,
          completed: completed, updatedAt: now,
        ).toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<ChapterProgress>> dirty() async =>
      [for (final r in await db.query('progress', where: 'dirty = 1', limit: 2000)) ChapterProgress.fromRow(r)];

  Future<void> markClean(Iterable<ChapterProgress> items) async {
    final batch = db.batch();
    for (final p in items) {
      batch.update('progress', {'dirty': 0},
          where: 'source_id = ? AND manga_id = ? AND chapter_id = ? AND updated_at <= ?',
          whereArgs: [p.sourceId, p.mangaId, p.chapterId, p.updatedAt.millisecondsSinceEpoch]);
    }
    await batch.commit(noResult: true);
  }

  Future<int> completedCount() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM progress WHERE completed = 1')) ?? 0;
}

class HistoryDao {
  HistoryDao(this.db);
  final Database db;

  Future<List<HistoryItem>> recent({int limit = 100, int offset = 0}) async => [
        for (final r in await db.query('history',
            where: 'deleted = 0', orderBy: 'read_at DESC', limit: limit, offset: offset))
          HistoryItem.fromRow(r),
      ];

  Future<List<HistoryItem>> all() async =>
      [for (final r in await db.query('history', where: 'deleted = 0')) HistoryItem.fromRow(r)];

  Future<void> upsert(HistoryItem h, {bool dirty = true}) =>
      db.insert('history', h.toRow(dirty: dirty), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> mergeRemote(HistoryItem h) async {
    final rows = await db.query('history', columns: ['duration_seconds', 'dirty'], where: 'id = ?', whereArgs: [h.id]);
    if (rows.isNotEmpty && (rows.first['dirty'] as int? ?? 0) == 1) return;
    await upsert(h, dirty: false);
  }

  Future<List<HistoryItem>> dirty() async =>
      [for (final r in await db.query('history', where: 'dirty = 1 AND deleted = 0', limit: 2000)) HistoryItem.fromRow(r)];

  Future<void> markClean(Iterable<String> ids) async {
    final batch = db.batch();
    for (final id in ids) {
      batch.update('history', {'dirty': 0}, where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<void> delete(String id) => db.update('history', {'deleted': 1}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteForManga(String sourceId, String mangaId) =>
      db.update('history', {'deleted': 1}, where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);

  Future<void> clear() => db.update('history', {'deleted': 1});
}

class TitleCacheDao {
  TitleCacheDao(this.db);
  final Database db;

  Future<void> put(TitleData t) => db.insert(
        'title_cache',
        {
          'source_id': t.manga.sourceId,
          'manga_id': t.manga.id,
          'details': jsonEncode(t.manga.toJson()),
          'chapters': jsonEncode([for (final c in t.chapters) c.toJson()]),
          'fetched_at': _now(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<(TitleData, DateTime)?> get(String sourceId, String mangaId) async {
    final rows = await db.query('title_cache', where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    final data = TitleData(
      manga: MangaDetails.fromJson((jsonDecode(r['details']! as String) as Map).cast()),
      chapters: [for (final c in jsonDecode(r['chapters']! as String) as List) Chapter.fromJson((c as Map).cast())],
      fromCache: true,
    );
    return (data, DateTime.fromMillisecondsSinceEpoch(r['fetched_at']! as int, isUtc: true));
  }
}

class TitlePrefsDao {
  TitlePrefsDao(this.db);
  final Database db;

  Future<ReadingMode?> readingMode(String sourceId, String mangaId) async {
    final rows = await db.query('title_prefs',
        columns: ['reading_mode'], where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]);
    final v = rows.isEmpty ? null : rows.first['reading_mode'] as String?;
    return v == null ? null : ReadingMode.parse(v);
  }

  Future<void> setReadingMode(String sourceId, String mangaId, ReadingMode mode) => db.insert(
      'title_prefs', {'source_id': sourceId, 'manga_id': mangaId, 'reading_mode': mode.api},
      conflictAlgorithm: ConflictAlgorithm.replace);
}

class SearchHistoryDao {
  SearchHistoryDao(this.db);
  final Database db;

  Future<List<String>> recent({int limit = 15}) async => [
        for (final r in await db.query('search_history', orderBy: 'created_at DESC', limit: limit)) r['query']! as String,
      ];

  Future<void> add(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    // strictly increasing timestamps keep ordering stable for rapid consecutive searches
    final last = Sqflite.firstIntValue(await db.rawQuery('SELECT MAX(created_at) FROM search_history')) ?? 0;
    final ts = _now() > last ? _now() : last + 1;
    await db.insert('search_history', {'query': query, 'created_at': ts}, conflictAlgorithm: ConflictAlgorithm.replace);
    await db.rawDelete(
        'DELETE FROM search_history WHERE query NOT IN (SELECT query FROM search_history ORDER BY created_at DESC LIMIT 50)');
  }

  Future<void> remove(String q) => db.delete('search_history', where: 'query = ?', whereArgs: [q]);
  Future<void> clear() => db.delete('search_history');
}

class UpdatesDao {
  UpdatesDao(this.db);
  final Database db;

  Future<List<ChapterUpdate>> all({int limit = 200}) async => [
        for (final r in await db.query('updates', orderBy: 'detected_at DESC', limit: limit))
          ChapterUpdate(
            id: r['id']! as String,
            sourceId: r['source_id']! as String,
            mangaId: r['manga_id']! as String,
            mangaTitle: r['manga_title'] as String? ?? '',
            coverUrl: r['cover_url'] as String? ?? '',
            chapterId: r['chapter_id']! as String,
            chapterTitle: r['chapter_title'] as String? ?? '',
            chapterNumber: (r['chapter_number'] as num?)?.toDouble(),
            detectedAt: DateTime.fromMillisecondsSinceEpoch(r['detected_at']! as int, isUtc: true),
            seen: (r['seen'] as int? ?? 0) == 1,
          ),
      ];

  /// Returns updates that were not stored before (for notifications).
  Future<List<ChapterUpdate>> addAll(List<ChapterUpdate> items) async {
    final fresh = <ChapterUpdate>[];
    for (final u in items) {
      final exists = await db.query('updates', columns: ['id'], where: 'id = ?', whereArgs: [u.id]);
      if (exists.isNotEmpty) continue;
      await db.insert(
          'updates',
          {
            'id': u.id,
            'source_id': u.sourceId,
            'manga_id': u.mangaId,
            'manga_title': u.mangaTitle,
            'cover_url': u.coverUrl,
            'chapter_id': u.chapterId,
            'chapter_title': u.chapterTitle,
            'chapter_number': u.chapterNumber,
            'detected_at': u.detectedAt.millisecondsSinceEpoch,
            'seen': u.seen ? 1 : 0,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore);
      fresh.add(u);
    }
    return fresh;
  }

  Future<void> markSeen({String? sourceId, String? mangaId}) => db.update('updates', {'seen': 1},
      where: sourceId == null ? null : 'source_id = ? AND manga_id = ?',
      whereArgs: sourceId == null ? null : [sourceId, mangaId]);

  Future<int> unseenCount() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM updates WHERE seen = 0')) ?? 0;
}

class KvDao {
  KvDao(this.db);
  final Database db;

  Future<String?> get(String key) async {
    final r = await db.query('kv', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  Future<void> set(String key, String? value) =>
      db.insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
}
