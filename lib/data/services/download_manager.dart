import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import '../models/manga.dart';
import '../models/settings.dart';
import 'downloads/download_engine.dart';
import 'downloads/download_runtime.dart';

/// Where a chapter's pages live: `<root>/downloads/<source>/<sha1(source|chapter)[:20]>`.
String downloadDirFor(String root, String sourceId, String chapterId) {
  final hash = sha1.convert('$sourceId|$chapterId'.codeUnits).toString().substring(0, 20);
  return p.join(root, 'downloads', sourceId, hash);
}

enum DownloadStatus { queued, downloading, completed, failed, paused, retrying }

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
    this.attempts = 0,
    this.nextAttemptAt,
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
  final int attempts;
  final DateTime? nextAttemptAt;

  String get key => '$sourceId:$chapterId';
  double get progress => pageCount == 0 ? 0 : pagesDone / pageCount;
  bool get isActive => status == DownloadStatus.queued || status == DownloadStatus.downloading || status == DownloadStatus.retrying;

  factory DownloadTask.fromRow(Map<String, Object?> r) {
    final next = r['next_attempt_at'] as int? ?? 0;
    return DownloadTask(
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
      attempts: r['attempts'] as int? ?? 0,
      nextAttemptAt: next == 0 ? null : DateTime.fromMillisecondsSinceEpoch(next, isUtc: true),
    );
  }
}

/// Engine-level state for the UI ("waiting for network", …).
enum DownloadsState { idle, running, waitingNetwork, waitingWifi, waitingRetry }

const kDownloadsWorkTask = 'mangaflow.downloads';

/// Queue facade used by the UI isolate.
///
/// The actual work is done by [DownloadEngine] — inside an Android foreground
/// service when possible (survives app close, holds wake/Wi-Fi locks, restarts
/// after reboot), otherwise in-process. A WorkManager job every 15 minutes is a
/// safety net that resumes the queue if the system killed everything.
class DownloadManager {
  DownloadManager({
    required this.db,
    required this.settings,
    this.onChapterCompleted,
    Future<Directory> Function()? rootDir,
    bool useService = true,
  })  : _rootDir = rootDir ?? getApplicationDocumentsDirectory,
        _useService = useService && DownloadService.supported {
    if (_useService) DownloadService.addListener(_onServiceData);
    unawaited(_reportCompleted()); // seeds the "already completed" set
  }

  final Database db;
  final AppSettings Function() settings;
  final void Function(DownloadTask task)? onChapterCompleted;
  final Future<Directory> Function() _rootDir;
  final bool _useService;

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  DownloadEngine? _local;
  Timer? _poll;
  final Set<String> _completedSeen = {};

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  void _onServiceData(Object _) {
    _changed();
    unawaited(_reportCompleted());
  }

  Future<String> _dirFor(String sourceId, String chapterId) async => downloadDirFor((await _rootDir()).path, sourceId, chapterId);

  Future<Directory> rootDir() => _rootDir();

  /// Lets other writers of the `downloads` table (chapter import) refresh the UI.
  void notifyChanged() => _changed();

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

  Future<DownloadsState> state() async {
    final r = await db.query('kv', where: 'key = ?', whereArgs: [DownloadEngine.stateKey]);
    return switch (r.isEmpty ? null : r.first['value']) {
      'running' => DownloadsState.running,
      'waiting_network' => DownloadsState.waitingNetwork,
      'waiting_wifi' => DownloadsState.waitingWifi,
      'waiting_retry' => DownloadsState.waitingRetry,
      _ => DownloadsState.idle,
    };
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

  Future<int> pendingCount() async =>
      Sqflite.firstIntValue(
          await db.rawQuery("SELECT COUNT(*) FROM downloads WHERE status IN ('queued','retrying','downloading')")) ??
      0;

  // ------------------------------------------------------------------ commands
  Future<void> enqueue({required MangaDetails manga, required List<Chapter> chapters}) async {
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final batch = db.batch();
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
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
          'created_at': now + i, // keeps the requested order
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      batch.update('downloads', {'status': 'queued', 'error': null, 'attempts': 0, 'next_attempt_at': 0},
          where: "source_id = ? AND chapter_id = ? AND status IN ('failed','paused')", whereArgs: [manga.sourceId, c.id]);
    }
    await batch.commit(noResult: true);
    _changed();
    await kick();
  }

  Future<void> retry(DownloadTask t) async {
    await db.update('downloads', {'status': 'queued', 'error': null, 'attempts': 0, 'next_attempt_at': 0},
        where: 'source_id = ? AND chapter_id = ?', whereArgs: [t.sourceId, t.chapterId]);
    _changed();
    await kick();
  }

  /// Retry everything that failed or is waiting for its backoff — right now.
  Future<void> retryAllFailed() async {
    await db.update('downloads', {'status': 'queued', 'error': null, 'attempts': 0, 'next_attempt_at': 0},
        where: "status IN ('failed','retrying')");
    _changed();
    await kick();
  }

  Future<void> pauseAll() async {
    await db.update('downloads', {'status': 'paused'}, where: "status IN ('queued','downloading','retrying')");
    _local?.stop();
    _changed();
  }

  Future<void> resumeAll() async {
    await db.update('downloads', {'status': 'queued', 'next_attempt_at': 0}, where: "status = 'paused'");
    _changed();
    await kick();
  }

  Future<void> delete(String sourceId, String chapterId) async {
    final t = await get(sourceId, chapterId);
    if (t == null) return;
    await db.delete('downloads', where: 'source_id = ? AND chapter_id = ?', whereArgs: [sourceId, chapterId]);
    final dir = Directory(t.dir);
    if (dir.existsSync()) await dir.delete(recursive: true);
    _changed();
  }

  Future<void> deleteManga(String sourceId, String mangaId) async {
    for (final t in (await forManga(sourceId, mangaId)).values) {
      await delete(t.sourceId, t.chapterId);
    }
  }

  /// App start / resume / connectivity change.
  Future<void> resumeInterrupted() => kick();

  /// Makes sure something is working on the queue.
  Future<void> kick() async {
    if (await pendingCount() == 0) return;
    await _registerSafetyNet();
    if (_useService && await DownloadService.ensureStarted()) {
      _startPolling();
      return;
    }
    _runLocal();
  }

  Future<void> _registerSafetyNet() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await Workmanager().registerPeriodicTask(
        kDownloadsWorkTask,
        kDownloadsWorkTask,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {
      // WorkManager not initialised (tests) — the service/in-process runner still works
    }
  }

  void _runLocal() {
    if (_local != null) return;
    final engine = buildEngine(
      db: db,
      owner: 'ui',
      settings: settings,
      onProgress: (_) {
        _changed();
        unawaited(_reportCompleted());
      },
    );
    _local = engine;
    unawaited(() async {
      try {
        while (true) {
          final r = await engine.run();
          if (r != RunResult.leaseBusy) break;
          await Future<void>.delayed(const Duration(seconds: 20));
        }
      } finally {
        _local = null;
        _changed();
      }
    }());
  }

  /// Fallback refresh while the service works (in case a message is missed).
  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 4), (_) async {
      _changed();
      await _reportCompleted();
      if (await pendingCount() == 0 && !await DownloadService.isRunning()) {
        _poll?.cancel();
        _poll = null;
      }
    });
  }

  bool _seeded = false;

  /// Reports chapters completed since this manager started (to the server registry).
  Future<void> _reportCompleted() async {
    final cb = onChapterCompleted;
    if (cb == null) return;
    final tasks = (await db.query('downloads', where: "status = 'completed'")).map(DownloadTask.fromRow).toList();
    if (!_seeded) {
      _seeded = true;
      _completedSeen.addAll(tasks.map((t) => t.key));
      return;
    }
    for (final t in tasks) {
      if (_completedSeen.add(t.key)) cb(t);
    }
  }

  void dispose() {
    if (_useService) DownloadService.removeListener(_onServiceData);
    _poll?.cancel();
    _local?.stop();
    _changes.close();
  }
}
