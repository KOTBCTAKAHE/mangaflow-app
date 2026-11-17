import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local SQLite database — the on-device source of truth (offline-first).
///
/// Every syncable table carries `updated_at` (ms since epoch, UTC) and a
/// `dirty` flag that the sync engine clears after a successful push.
class AppDatabase {
  AppDatabase._(this.db);
  final Database db;

  static const version = 2;

  /// [singleInstance] must be false for background isolates: sqflite shares one
  /// native handle per path, so closing it there would close the app's database too.
  static Future<AppDatabase> open({String? path, DatabaseFactory? factory, bool singleInstance = true}) async {
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), 'mangaflow.db');
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: version,
        singleInstance: singleInstance,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          // Several isolates (UI, download service, WorkManager) share the file:
          // WAL + busy timeout avoid "database is locked" under concurrent writes.
          await db.rawQuery('PRAGMA busy_timeout = 8000');
          if (dbPath != inMemoryDatabasePath) await db.rawQuery('PRAGMA journal_mode = WAL');
        },
        onCreate: (db, v) async {
          final batch = db.batch();
          for (final stmt in _schemaV1) {
            batch.execute(stmt);
          }
          await batch.commit(noResult: true);
          await _migrate(db, 1, v);
        },
        onUpgrade: _migrate,
      ),
    );
    return AppDatabase._(db);
  }

  Future<void> close() => db.close();

  Future<void> clearUserData() async {
    final batch = db.batch();
    for (final t in const ['library', 'collections', 'collection_items', 'progress', 'history', 'updates']) {
      batch.delete(t);
    }
    await batch.commit(noResult: true);
  }

  static Future<void> _migrate(Database db, int from, int to) async {
    if (from < 2) {
      // resilient downloads: retry bookkeeping
      await db.execute('ALTER TABLE downloads ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0');
      await db.execute('ALTER TABLE downloads ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0');
      await db.execute('CREATE INDEX ix_downloads_queue ON downloads(status, next_attempt_at)');
    }
  }

  static const _schemaV1 = <String>[
    '''CREATE TABLE library (
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      title TEXT NOT NULL,
      cover_url TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'planned',
      is_favorite INTEGER NOT NULL DEFAULT 0,
      reader_settings TEXT,
      total_chapters INTEGER,
      last_chapter_number REAL,
      last_read_at INTEGER,
      added_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      deleted INTEGER NOT NULL DEFAULT 0,
      unread_updates INTEGER NOT NULL DEFAULT 0,
      dirty INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (source_id, manga_id)
    )''',
    'CREATE INDEX ix_library_status ON library(status, deleted)',
    '''CREATE TABLE collections (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      position INTEGER NOT NULL DEFAULT 0,
      remote_id TEXT
    )''',
    '''CREATE TABLE collection_items (
      collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      PRIMARY KEY (collection_id, source_id, manga_id)
    )''',
    '''CREATE TABLE progress (
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      chapter_number REAL,
      chapter_title TEXT NOT NULL DEFAULT '',
      page_index INTEGER NOT NULL DEFAULT 0,
      page_count INTEGER NOT NULL DEFAULT 0,
      completed INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      dirty INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY (source_id, manga_id, chapter_id)
    )''',
    'CREATE INDEX ix_progress_manga ON progress(source_id, manga_id, updated_at)',
    '''CREATE TABLE history (
      id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      manga_title TEXT NOT NULL DEFAULT '',
      cover_url TEXT NOT NULL DEFAULT '',
      chapter_id TEXT NOT NULL,
      chapter_title TEXT NOT NULL DEFAULT '',
      chapter_number REAL,
      started_at INTEGER NOT NULL,
      read_at INTEGER NOT NULL,
      duration_seconds INTEGER NOT NULL DEFAULT 0,
      pages_read INTEGER NOT NULL DEFAULT 0,
      deleted INTEGER NOT NULL DEFAULT 0,
      dirty INTEGER NOT NULL DEFAULT 1
    )''',
    'CREATE INDEX ix_history_read_at ON history(read_at)',
    '''CREATE TABLE downloads (
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      chapter_id TEXT NOT NULL,
      manga_title TEXT NOT NULL DEFAULT '',
      chapter_title TEXT NOT NULL DEFAULT '',
      chapter_number REAL,
      cover_url TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL DEFAULT 'queued',
      page_count INTEGER NOT NULL DEFAULT 0,
      pages_done INTEGER NOT NULL DEFAULT 0,
      size_bytes INTEGER NOT NULL DEFAULT 0,
      error TEXT,
      dir TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, chapter_id)
    )''',
    'CREATE INDEX ix_downloads_manga ON downloads(source_id, manga_id)',
    '''CREATE TABLE title_cache (
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      details TEXT NOT NULL,
      chapters TEXT NOT NULL,
      fetched_at INTEGER NOT NULL,
      PRIMARY KEY (source_id, manga_id)
    )''',
    '''CREATE TABLE title_prefs (
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      reading_mode TEXT,
      chapter_sort TEXT,
      PRIMARY KEY (source_id, manga_id)
    )''',
    '''CREATE TABLE search_history (
      query TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE updates (
      id TEXT PRIMARY KEY,
      source_id TEXT NOT NULL,
      manga_id TEXT NOT NULL,
      manga_title TEXT NOT NULL DEFAULT '',
      cover_url TEXT NOT NULL DEFAULT '',
      chapter_id TEXT NOT NULL,
      chapter_title TEXT NOT NULL DEFAULT '',
      chapter_number REAL,
      detected_at INTEGER NOT NULL,
      seen INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE kv (
      key TEXT PRIMARY KEY,
      value TEXT
    )''',
  ];
}
