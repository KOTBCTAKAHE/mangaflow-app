import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../core/config.dart';
import '../../core/network/api_client.dart';
import '../../core/storage/database.dart';
import '../../core/storage/secure_store.dart';
import '../local/daos.dart';
import '../models/reading.dart';
import '../models/settings.dart';
import '../remote/catalog_api.dart';
import '../remote/user_api.dart';
import '../repositories/auth_repository.dart';
import 'notifications.dart';

const kUpdateTask = 'mangaflow.checkUpdates';

/// Entry point for the background isolate (Android WorkManager / iOS BGTask).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await BackgroundUpdates.run();
      return true;
    } catch (_) {
      return false; // WorkManager retries with backoff
    }
  });
}

class BackgroundUpdates {
  static Future<void> register() async {
    await Workmanager().initialize(backgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      kUpdateTask,
      kUpdateTask,
      frequency: const Duration(hours: 6),
      constraints: Constraints(networkType: NetworkType.connected, requiresBatteryNotLow: true),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  static Future<void> cancel() => Workmanager().cancelByUniqueName(kUpdateTask);

  /// Signed-in users: pull the server-side update feed.
  /// Guests: compare chapter counts of library titles via the catalog API.
  static Future<void> run() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_settings_v1');
    final settings = raw == null
        ? AppSettings(apiBaseUrl: AppConfig.defaultApiBaseUrl, updatedAt: DateTime.now())
        : AppSettings.fromJson((jsonDecode(raw) as Map).cast(), fallbackUrl: AppConfig.defaultApiBaseUrl);
    if (!settings.notifyUpdates) return;

    final db = await AppDatabase.open();
    try {
      final client = ApiClient(baseUrl: settings.apiBaseUrl);
      final auth = AuthController(client, SecureStore());
      await auth.restore();
      final updatesDao = UpdatesDao(db.db);
      final libraryDao = LibraryDao(db.db);
      final kv = KvDao(db.db);
      List<ChapterUpdate> fresh;

      if (auth.isSignedIn) {
        final since = DateTime.tryParse(await kv.get('since_updates') ?? '');
        final items = await UserApi(client).updates(unseen: true, since: since);
        fresh = await updatesDao.addAll(items);
        if (items.isNotEmpty) {
          final newest = items.map((u) => u.detectedAt).reduce((a, b) => a.isAfter(b) ? a : b);
          await kv.set('since_updates', newest.toIso8601String());
        }
      } else {
        fresh = await _guestCheck(CatalogApi(client), libraryDao, updatesDao, TitleCacheDao(db.db));
      }
      for (final u in fresh) {
        final entry = await libraryDao.get(u.sourceId, u.mangaId);
        if (entry != null) await libraryDao.setUnread(u.sourceId, u.mangaId, entry.unreadUpdates + 1);
      }
      await Notifier.instance.showNewChapters(fresh);
    } finally {
      await db.close();
    }
  }

  static Future<List<ChapterUpdate>> _guestCheck(
      CatalogApi api, LibraryDao library, UpdatesDao updates, TitleCacheDao cache) async {
    final entries = (await library.all())
        .where((e) => e.status.api == 'reading' || e.status.api == 'planned' || e.status.api == 'on_hold')
        .take(40)
        .toList();
    final found = <ChapterUpdate>[];
    for (final e in entries) {
      try {
        final before = await cache.get(e.sourceId, e.mangaId);
        final known = before == null ? null : {for (final c in before.$1.chapters) c.id};
        final now = await api.title(e.sourceId, e.mangaId);
        await cache.put(now);
        if (known == null) continue; // first look: baseline only
        for (final c in now.chapters.where((c) => !known.contains(c.id)).take(20)) {
          found.add(ChapterUpdate(
            id: '${e.sourceId}:${c.id}',
            sourceId: e.sourceId,
            mangaId: e.mangaId,
            mangaTitle: e.title,
            coverUrl: e.coverUrl,
            chapterId: c.id,
            chapterTitle: c.title,
            chapterNumber: c.number,
            detectedAt: DateTime.now().toUtc(),
          ));
        }
      } catch (_) {
        continue; // one failing source must not stop the others
      }
    }
    return updates.addAll(found);
  }
}
