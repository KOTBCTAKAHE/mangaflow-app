import 'package:sqflite/sqflite.dart';

/// A page someone wanted to come back to, with an optional note.
class Bookmark {
  const Bookmark({
    required this.id,
    required this.sourceId,
    required this.mangaId,
    required this.chapterId,
    required this.pageIndex,
    required this.createdAt,
    this.mangaTitle = '',
    this.coverUrl = '',
    this.chapterTitle = '',
    this.chapterNumber,
    this.note = '',
  });

  final String id;
  final String sourceId;
  final String mangaId;
  final String mangaTitle;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final double? chapterNumber;
  final int pageIndex;
  final String note;
  final DateTime createdAt;

  static String idFor(String sourceId, String chapterId, int page) => '$sourceId|$chapterId|$page';

  Map<String, Object?> toRow() => {
        'id': id,
        'source_id': sourceId,
        'manga_id': mangaId,
        'manga_title': mangaTitle,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_number': chapterNumber,
        'page_index': pageIndex,
        'note': note,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory Bookmark.fromRow(Map<String, Object?> r) => Bookmark(
        id: r['id']! as String,
        sourceId: r['source_id']! as String,
        mangaId: r['manga_id']! as String,
        mangaTitle: r['manga_title'] as String? ?? '',
        coverUrl: r['cover_url'] as String? ?? '',
        chapterId: r['chapter_id']! as String,
        chapterTitle: r['chapter_title'] as String? ?? '',
        chapterNumber: (r['chapter_number'] as num?)?.toDouble(),
        pageIndex: r['page_index'] as int? ?? 0,
        note: r['note'] as String? ?? '',
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at']! as int),
      );
}

class BookmarksDao {
  BookmarksDao(this.db);
  final Database db;

  Future<void> put(Bookmark b) => db.insert('bookmarks', b.toRow(), conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> delete(String id) => db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);

  Future<Bookmark?> get(String id) async {
    final r = await db.query('bookmarks', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Bookmark.fromRow(r.first);
  }

  Future<List<Bookmark>> all() async =>
      [for (final r in await db.query('bookmarks', orderBy: 'created_at DESC')) Bookmark.fromRow(r)];

  Future<List<Bookmark>> forManga(String sourceId, String mangaId) async => [
        for (final r in await db.query('bookmarks',
            where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId], orderBy: 'chapter_number DESC, page_index ASC'))
          Bookmark.fromRow(r),
      ];

  Future<Set<String>> idsForChapter(String sourceId, String chapterId) async => {
        for (final r in await db.query('bookmarks', columns: ['id'], where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]))
          r['id']! as String,
      };
}
