import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/config.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
import '../../core/storage/secure_store.dart';
import '../local/daos.dart';
import '../models/library.dart';
import '../models/manga.dart';
import '../models/settings.dart';
import '../remote/catalog_api.dart';
import '../repositories/auth_repository.dart';
import 'download_manager.dart';
import 'downloads/download_runtime.dart';
import 'notifications.dart';

const kAutoDownloadTask = 'mangaflow.autoDownload';

/// How many unread chapters ahead we keep downloaded per title.
const kAutoDownloadAhead = 5;

/// «Автоскачивание новых глав»: for «Читаю» titles keep the next unread
/// chapters on the phone. Runs only on Wi-Fi while charging (WorkManager
/// constraints), then hands the queue to the download service.
abstract final class AutoDownload {
  static Future<void> sync(bool enabled) async {
    try {
      if (!enabled) {
        await Workmanager().cancelByUniqueName(kAutoDownloadTask);
        return;
      }
      await Workmanager().registerPeriodicTask(
        kAutoDownloadTask,
        kAutoDownloadTask,
        frequency: const Duration(hours: 3),
        initialDelay: const Duration(minutes: 5),
        constraints: Constraints(networkType: NetworkType.unmetered, requiresCharging: true),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (_) {
      // WorkManager unavailable (tests / iOS)
    }
  }

  /// Chapters to fetch for one title: unread ones after the last finished, oldest first.
  static List<Chapter> pick(List<Chapter> chapters, {double? lastRead, required Set<String> have, int limit = kAutoDownloadAhead}) {
    final unread = chapters.where((c) => c.number != null && (lastRead == null || c.number! > lastRead) && !have.contains(c.id)).toList()
      ..sort((a, b) => a.number!.compareTo(b.number!));
    return unread.take(limit).toList();
  }

  /// Background entry (WorkManager isolate). Returns the number of chapters queued.
  static Future<int> run() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString('app_settings_v1');
    if (raw == null) return 0;
    final settings = AppSettings.fromJson((jsonDecode(raw) as Map).cast(), fallbackUrl: AppConfig.defaultApiBaseUrl);
    if (!settings.autoDownloadNew) return 0;

    final database = await AppDatabase.open(singleInstance: false);
    var queued = 0;
    try {
      final client = ApiClient(baseUrl: settings.apiBaseUrl);
      final auth = AuthController(client, SecureStore());
      await auth.restore();
      final api = CatalogApi(client);
      final library = LibraryDao(database.db);
      final progress = ProgressDao(database.db);
      final cache = TitleCacheDao(database.db);
      final root = (await getApplicationDocumentsDirectory()).path;
      final reading = (await library.all()).where((e) => e.status == LibraryStatus.reading).take(30);
      final now = DateTime.now().toUtc().millisecondsSinceEpoch;
      for (final e in reading) {
        try {
          final t = await api.title(e.sourceId, e.mangaId);
          await cache.put(t);
          final done = (await progress.forManga(e.sourceId, e.mangaId)).values.where((p) => p.completed);
          double? lastRead = e.lastChapterNumber;
          for (final p in done) {
            final n = p.chapterNumber;
            if (n != null && (lastRead == null || n > lastRead)) lastRead = n;
          }
          final rows = await database.db.query('downloads',
              columns: ['chapter_id'], where: 'source_id = ? AND manga_id = ?', whereArgs: [e.sourceId, e.mangaId]);
          final have = {for (final r in rows) r['chapter_id'] as String};
          final picked = pick(t.chapters, lastRead: lastRead, have: have);
          final batch = database.db.batch();
          for (var i = 0; i < picked.length; i++) {
            final c = picked[i];
            batch.insert('downloads', {
              'source_id': e.sourceId,
              'manga_id': e.mangaId,
              'chapter_id': c.id,
              'manga_title': t.manga.title,
              'chapter_title': c.title,
              'chapter_number': c.number,
              'cover_url': t.manga.coverUrl,
              'status': DownloadStatus.queued.name,
              'dir': downloadDirFor(root, e.sourceId, c.id),
              'created_at': now + queued + i,
              'updated_at': now,
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
          await batch.commit(noResult: true);
          queued += picked.length;
        } catch (_) {
          continue; // one source down must not stop the rest
        }
      }
      if (queued == 0) return 0;
      // Prefer the foreground service (survives, holds Wi-Fi/wake locks)…
      try {
        DownloadService.initOptions();
        if (await DownloadService.ensureStarted()) {
          await ChapterNotifier.instance.showInfo(7101, 'Скачиваю новые главы', 'В очереди: $queued — для чтения без интернета');
          return queued;
        }
      } catch (_) {}
      // …else work right here within WorkManager's window.
      final ps = PrefsSettings(prefs);
      try {
        await buildEngine(db: database.db, owner: 'autodownload', settings: () => ps.value).run(budget: const Duration(minutes: 8));
      } finally {
        ps.dispose();
      }
      await ChapterNotifier.instance.showInfo(7101, 'Новые главы скачаны', 'Готово к чтению без интернета: $queued');
    } finally {
      await database.close();
    }
    return queued;
  }
}
