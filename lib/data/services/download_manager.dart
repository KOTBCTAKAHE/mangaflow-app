import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/network/api_exception.dart';
import '../models/manga.dart';
import '../models/settings.dart';
import '../remote/catalog_api.dart';

enum DownloadStatus { queued, downloading, completed, failed, paused }

class DownloadTask {
  const DownloadTask({
    required this.sourceId,
    required this.mangaId,
    required this.chapterId,
    required this.mangaTitle,
    required this.chapterTitle,
    required this.status,
    required this.dir,
    this.chapterNumber,
    this.coverUrl = '',
    this.pageCount = 0,
    this.pagesDone = 0,
    this.sizeBytes = 0,
    this.error,
  });

  final String sourceId;
  final String mangaId;
  final String chapterId;
  final String mangaTitle;
  final String chapterTitle;
  final double? chapterNumber;
  final String coverUrl;
  final DownloadStatus status;
  final int pageCount;
  final int pagesDone;
  final int sizeBytes;
  final String? error;
  final String dir;

  String get key => '$sourceId:$chapterId';
  double get progress => pageCount == 0 ? 0 : pagesDone / pageCount;

  factory DownloadTask.fromRow(Map<String, Object?> r) => DownloadTask(
        sourceId: r['source_id']! as String,
        mangaId: r['manga_id']! as String,
        chapterId: r['chapter_id']! as String,
        mangaTitle: r['manga_title'] as String? ?? '',
        chapterTitle: r['chapter_title'] as String? ?? '',
        chapterNumber: (r['chapter_number'] as num?)?.toDouble(),
        coverUrl: r['cover_url'] as String? ?? '',
        status: DownloadStatus.values.byName(r['status']! as String),
        pageCount: r['page_count'] as int? ?? 0,
        pagesDone: r['pages_done'] as int? ?? 0,
        sizeBytes: r['size_bytes'] as int? ?? 0,
        error: r['error'] as String?,
        dir: r['dir']! as String,
      );
}

/// Persistent, resumable chapter downloader.
///
/// * The queue lives in SQLite, so it survives app restarts; interrupted
///   downloads resume and already-saved pages are skipped.
/// * One chapter at a time, a few pages in parallel, retries per page.
/// * Broken/partial files are written to `*.part` and renamed atomically.
class DownloadManager {
  DownloadManager({
    required this.db,
    required this.api,
    required this.settings,
    this.onChapterCompleted,
    Dio? http,
    Future<Directory> Function()? rootDir,
  })  : _http = http ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 60))),
        _rootDir = rootDir ?? getApplicationDocumentsDirectory;

  final Database db;
  final CatalogApi api;
  final AppSettings Function() settings;
  final void Function(DownloadTask task)? onChapterCompleted;
  final Dio _http;
  final Future<Directory> Function() _rootDir;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  bool _running = false;
  CancelToken? _cancel;
  String? _activeKey;

  static const _pageParallelism = 3;
  static const _pageRetries = 3;

  Future<String> _dirFor(String sourceId, String chapterId) async {
    final root = await _rootDir();
    final hash = sha1.convert('$sourceId|$chapterId'.codeUnits).toString().substring(0, 20);
    return p.join(root.path, 'downloads', sourceId, hash);
  }

  // ------------------------------------------------------------------ queries
  Future<List<DownloadTask>> all() async =>
      [for (final r in await db.query('downloads', orderBy: 'created_at ASC')) DownloadTask.fromRow(r)];

  Future<Map<String, DownloadTask>> forManga(String sourceId, String mangaId) async => {
        for (final r in await db.query('downloads', where: 'source_id = ? AND manga_id = ?', whereArgs: [sourceId, mangaId]))
          r['chapter_id']! as String: DownloadTask.fromRow(r),
      };

  Future<DownloadTask?> get(String sourceId, String chapterId) async {
    final r = await db.query('downloads', where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]);
    return r.isEmpty ? null : DownloadTask.fromRow(r.first);
  }

  /// Pages on disk for a completed download, or null.
  Future<List<PageRef>?> localPages(String sourceId, String chapterId) async {
    final t = await get(sourceId, chapterId);
    if (t == null || t.status != DownloadStatus.completed) return null;
    final dir = Directory(t.dir);
    if (!dir.existsSync()) return null;
    final files = dir.listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).toList()
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    if (files.isEmpty) return null;
    return [for (var i = 0; i < files.length; i++) PageRef(index: i, url: files[i].uri.toString(), localPath: files[i].path)];
  }

  Future<int> totalBytes() async =>
      Sqflite.firstIntValue(await db.rawQuery("SELECT COALESCE(SUM(size_bytes),0) FROM downloads WHERE status='completed'")) ?? 0;

  // ------------------------------------------------------------------ commands
  Future<void> enqueue({
    required MangaDetails manga,
    required List<Chapter> chapters,
  }) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final c in chapters) {
      batch.insert(
        'downloads',
        {
          'source_id': manga.sourceId,
          'manga_id': manga.id,
          'chapter_id': c.id,
          'manga_title': manga.title,
          'chapter_title': c.title,
          'chapter_number': c.number,
          'cover_url': manga.coverUrl,
          'status': DownloadStatus.queued.name,
          'dir': await _dirFor(manga.sourceId, c.id),
          'created_at': now,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
    // re-queue failed ones that the user asked for again
    for (final c in chapters) {
      await db.update('downloads', {'status': DownloadStatus.queued.name, 'error': null},
          where: "source_id = ? AND chapter_id = ? AND status IN ('failed','paused')", whereArgs: [manga.sourceId, c.id]);
    }
    _changes.add(null);
    unawaited(_run());
  }

  Future<void> retry(DownloadTask t) async {
    await _setStatus(t.sourceId, t.chapterId, DownloadStatus.queued, error: null);
    unawaited(_run());
  }

  Future<void> retryAllFailed() async {
    await db.update('downloads', {'status': DownloadStatus.queued.name, 'error': null}, where: "status = 'failed'");
    _changes.add(null);
    unawaited(_run());
  }

  Future<void> pauseAll() async {
    await db.update('downloads', {'status': DownloadStatus.paused.name}, where: "status IN ('queued','downloading')");
    _cancel?.cancel();
    _changes.add(null);
  }

  Future<void> resumeAll() async {
    await db.update('downloads', {'status': DownloadStatus.queued.name}, where: "status = 'paused'");
    _changes.add(null);
    unawaited(_run());
  }

  Future<void> delete(String sourceId, String chapterId) async {
    final t = await get(sourceId, chapterId);
    if (t == null) return;
    if (_activeKey == t.key) _cancel?.cancel();
    final dir = Directory(t.dir);
    if (dir.existsSync()) await dir.delete(recursive: true);
    await db.delete('downloads', where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]);
    _changes.add(null);
  }

  Future<void> deleteManga(String sourceId, String mangaId) async {
    for (final t in (await forManga(sourceId, mangaId)).values) {
      await delete(t.sourceId, t.chapterId);
    }
  }

  /// Call on app start: interrupted downloads go back to the queue.
  Future<void> resumeInterrupted() async {
    await db.update('downloads', {'status': DownloadStatus.queued.name}, where: "status = 'downloading'");
    unawaited(_run());
  }

  // ------------------------------------------------------------------ worker
  Future<bool> _networkAllowed() async {
    final results = await Connectivity().checkConnectivity();
    if (results.contains(ConnectivityResult.none) || results.isEmpty) return false;
    if (settings().downloadWifiOnly) {
      return results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet);
    }
    return true;
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final rows = await db.query('downloads', where: "status = 'queued'", orderBy: 'created_at ASC', limit: 1);
        if (rows.isEmpty) break;
        if (!await _networkAllowed()) break; // retried on next enqueue / app start / connectivity change
        await _download(DownloadTask.fromRow(rows.first));
      }
    } finally {
      _running = false;
    }
  }

  /// Triggered by the connectivity listener.
  void kick() => unawaited(_run());

  Future<void> _download(DownloadTask t) async {
    _activeKey = t.key;
    _cancel = CancelToken();
    await _setStatus(t.sourceId, t.chapterId, DownloadStatus.downloading);
    try {
      final width = settings().imageQuality.width;
      final pages = await api.pages(t.sourceId, t.chapterId, width: width);
      if (pages.isEmpty) throw const ApiException('chapter_empty', 'В главе нет страниц');
      final dir = Directory(t.dir);
      await dir.create(recursive: true);
      await db.update('downloads', {'page_count': pages.length},
          where: 'source_id = ? AND chapter_id = ?', whereArgs: [t.sourceId, t.chapterId]);

      var done = 0;
      var bytes = 0;
      final queue = [...pages];
      Future<void> worker() async {
        while (queue.isNotEmpty) {
          if (_cancel?.isCancelled ?? false) return;
          final page = queue.removeAt(0);
          final size = await _savePage(page, dir.path);
          done++;
          bytes += size;
          await db.update('downloads', {'pages_done': done, 'size_bytes': bytes},
              where: 'source_id = ? AND chapter_id = ?', whereArgs: [t.sourceId, t.chapterId]);
          _changes.add(null);
        }
      }

      await Future.wait([for (var i = 0; i < _pageParallelism; i++) worker()]);
      if (_cancel?.isCancelled ?? false) return;
      await db.update(
          'downloads',
          {
            'status': DownloadStatus.completed.name,
            'pages_done': pages.length,
            'size_bytes': bytes,
            'error': null,
            'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch,
          },
          where: 'source_id = ? AND chapter_id = ?',
          whereArgs: [t.sourceId, t.chapterId]);
      final finished = await get(t.sourceId, t.chapterId);
      if (finished != null) onChapterCompleted?.call(finished);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return;
      await _setStatus(t.sourceId, t.chapterId, DownloadStatus.failed, error: ApiException.fromDio(e).userMessage);
    } on ApiException catch (e) {
      await _setStatus(t.sourceId, t.chapterId, DownloadStatus.failed, error: e.userMessage);
    } catch (e) {
      await _setStatus(t.sourceId, t.chapterId, DownloadStatus.failed, error: e.toString());
    } finally {
      _activeKey = null;
      _changes.add(null);
    }
  }

  /// Downloads one page (skipping if present). Returns its size in bytes.
  Future<int> _savePage(PageRef page, String dir) async {
    final base = page.index.toString().padLeft(4, '0');
    final existing = Directory(dir)
        .listSync()
        .whereType<File>()
        .where((f) => p.basenameWithoutExtension(f.path) == base && !f.path.endsWith('.part'));
    if (existing.isNotEmpty) return existing.first.lengthSync();

    Object? lastError;
    for (var attempt = 0; attempt < _pageRetries; attempt++) {
      final tmp = p.join(dir, '$base.part');
      try {
        final res = await _http.download(page.url, tmp, cancelToken: _cancel,
            options: Options(responseType: ResponseType.bytes, followRedirects: true));
        final type = res.headers.value('content-type') ?? '';
        final ext = switch (type) {
          final t when t.contains('webp') => 'webp',
          final t when t.contains('png') => 'png',
          final t when t.contains('gif') => 'gif',
          final t when t.contains('avif') => 'avif',
          _ => 'jpg',
        };
        final file = File(tmp);
        final size = await file.length();
        if (size < 64) throw const ApiException('image_invalid', 'Повреждённое изображение');
        await file.rename(p.join(dir, '$base.$ext'));
        return size;
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) rethrow;
        lastError = e;
        final code = e.response?.statusCode ?? 0;
        if (code == 404 || code == 403) break;
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    if (lastError is DioException) throw lastError;
    throw const ApiException('image_failed', 'Не удалось скачать страницу');
  }

  Future<void> _setStatus(String sourceId, String chapterId, DownloadStatus s, {String? error}) async {
    await db.update(
        'downloads',
        {'status': s.name, 'error': error, 'updated_at': DateTime.now().toUtc().millisecondsSinceEpoch},
        where: 'source_id = ? AND chapter_id = ?',
        whereArgs: [sourceId, chapterId]);
    _changes.add(null);
  }

  void dispose() {
    _cancel?.cancel();
    _changes.close();
  }
}
