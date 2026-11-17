import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/local/daos.dart';
import '../data/models/library.dart';
import '../data/models/reading.dart';
import '../data/models/settings.dart';
import '../data/remote/catalog_api.dart';
import '../data/remote/user_api.dart';
import '../data/repositories/auth_repository.dart';
import '../data/repositories/catalog_repository.dart';
import '../data/repositories/library_repository.dart';
import '../data/repositories/reading_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/services/backup_service.dart';
import '../data/services/download_manager.dart';
import '../data/services/notifications.dart';
import '../data/services/sync_engine.dart';
import 'network/api_client.dart';
import 'storage/database.dart';
import 'storage/secure_store.dart';

// ---------------------------------------------------------------- overridden in main()
final databaseProvider = Provider<AppDatabase>((_) => throw UnimplementedError('override in main'));
final prefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError('override in main'));
final secureStoreProvider = Provider<SecureStore>((_) => SecureStore());

// ---------------------------------------------------------------- settings
final settingsProvider = StateNotifierProvider<SettingsController, AppSettings>(
  (ref) => SettingsController(ref.watch(prefsProvider)),
);

// ---------------------------------------------------------------- network
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(baseUrl: ref.read(settingsProvider).apiBaseUrl);
  ref.listen<String>(settingsProvider.select((s) => s.apiBaseUrl), (_, next) => client.baseUrl = next);
  return client;
});

final authProvider = StateNotifierProvider<AuthController, AuthState>(
  (ref) => AuthController(ref.watch(apiClientProvider), ref.watch(secureStoreProvider)),
);

final catalogApiProvider = Provider((ref) => CatalogApi(ref.watch(apiClientProvider)));
final userApiProvider = Provider((ref) => UserApi(ref.watch(apiClientProvider)));

// ---------------------------------------------------------------- local data
final _db = Provider((ref) => ref.watch(databaseProvider).db);
final libraryDaoProvider = Provider((ref) => LibraryDao(ref.watch(_db)));
final collectionsDaoProvider = Provider((ref) => CollectionsDao(ref.watch(_db)));
final progressDaoProvider = Provider((ref) => ProgressDao(ref.watch(_db)));
final historyDaoProvider = Provider((ref) => HistoryDao(ref.watch(_db)));
final titleCacheDaoProvider = Provider((ref) => TitleCacheDao(ref.watch(_db)));
final titlePrefsDaoProvider = Provider((ref) => TitlePrefsDao(ref.watch(_db)));
final searchHistoryDaoProvider = Provider((ref) => SearchHistoryDao(ref.watch(_db)));
final updatesDaoProvider = Provider((ref) => UpdatesDao(ref.watch(_db)));
final kvDaoProvider = Provider((ref) => KvDao(ref.watch(_db)));

/// Bumped on every local data change; list providers watch it to refresh.
final dataVersionProvider = StateProvider<int>((_) => 0);

void _bump(Ref ref) {
  final n = ref.read(dataVersionProvider.notifier);
  scheduleMicrotask(() => n.state++);
}

// ---------------------------------------------------------------- services
final downloadManagerProvider = Provider<DownloadManager>((ref) {
  final m = DownloadManager(
    db: ref.watch(_db),
    settings: () => ref.read(settingsProvider),
    onChapterCompleted: (t) {
      if (!ref.read(authProvider.notifier).isSignedIn) return;
      unawaited(ref.read(userApiProvider).reportDownloads([
        {
          'device_id': ref.read(deviceIdProvider),
          'source_id': t.sourceId,
          'manga_id': t.mangaId,
          'chapter_id': t.chapterId,
          'manga_title': t.mangaTitle,
          'chapter_title': t.chapterTitle,
          'status': 'completed',
          'page_count': t.pageCount,
          'size_bytes': t.sizeBytes,
        }
      ]).catchError((Object _) {}));
    },
  );
  final sub = Connectivity().onConnectivityChanged.listen((_) => m.kick());
  ref.onDispose(() {
    sub.cancel();
    m.dispose();
  });
  return m;
});

final deviceIdProvider = Provider<String>((ref) {
  final prefs = ref.watch(prefsProvider);
  var id = prefs.getString('device_id');
  if (id == null) {
    id = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    prefs.setString('device_id', id);
  }
  return id;
});

final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    api: ref.watch(userApiProvider),
    library: ref.watch(libraryDaoProvider),
    collections: ref.watch(collectionsDaoProvider),
    progress: ref.watch(progressDaoProvider),
    history: ref.watch(historyDaoProvider),
    updates: ref.watch(updatesDaoProvider),
    kv: ref.watch(kvDaoProvider),
    settings: ref.read(settingsProvider.notifier),
    isSignedIn: () => ref.read(authProvider.notifier).isSignedIn,
    onPulled: () => _bump(ref),
    onNewUpdates: (fresh) {
      if (ref.read(settingsProvider).notifyUpdates) unawaited(ChapterNotifier.instance.showNewChapters(fresh));
    },
  );
  ref.onDispose(engine.dispose);
  return engine;
});

void _changed(Ref ref) {
  _bump(ref);
  ref.read(syncEngineProvider).schedule();
}

final catalogRepositoryProvider = Provider((ref) => CatalogRepository(
      api: ref.watch(catalogApiProvider),
      titleCache: ref.watch(titleCacheDaoProvider),
      kv: ref.watch(kvDaoProvider),
      downloads: ref.watch(downloadManagerProvider),
      settings: () => ref.read(settingsProvider),
    ));

final libraryRepositoryProvider = Provider((ref) => LibraryRepository(
      library: ref.watch(libraryDaoProvider),
      collections: ref.watch(collectionsDaoProvider),
      onChanged: () => _changed(ref),
      onCollectionDeleted: (remoteId) async {
        if (ref.read(authProvider.notifier).isSignedIn) await ref.read(userApiProvider).deleteCollection(remoteId);
      },
    ));

final readingRepositoryProvider = Provider((ref) => ReadingRepository(
      progress: ref.watch(progressDaoProvider),
      history: ref.watch(historyDaoProvider),
      library: ref.watch(libraryRepositoryProvider),
      titleCache: ref.watch(titleCacheDaoProvider),
      onChanged: () => _changed(ref),
    ));

final backupServiceProvider = Provider((ref) => BackupService(
      db: ref.watch(_db),
      library: ref.watch(libraryDaoProvider),
      collections: ref.watch(collectionsDaoProvider),
      progress: ref.watch(progressDaoProvider),
      history: ref.watch(historyDaoProvider),
      settings: ref.read(settingsProvider.notifier),
    ));

// ---------------------------------------------------------------- shared read models
final libraryEntriesProvider = FutureProvider<List<LibraryEntry>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(libraryRepositoryProvider).all();
});

final collectionsProvider = FutureProvider<List<Collection>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(libraryRepositoryProvider).allCollections();
});

final continueReadingProvider = FutureProvider<List<ContinueItem>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(readingRepositoryProvider).continueReading();
});

final unseenUpdatesProvider = FutureProvider<int>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(updatesDaoProvider).unseenCount();
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final engine = ref.watch(syncEngineProvider);
  final controller = StreamController<SyncStatus>();
  void listener() => controller.add(engine.status.value);
  engine.status.addListener(listener);
  controller.add(engine.status.value);
  ref.onDispose(() {
    engine.status.removeListener(listener);
    controller.close();
  });
  return controller.stream;
});

/// Emits an increasing counter on every download change (distinct values → listeners always rebuild).
final downloadsChangesProvider = StreamProvider<int>((ref) {
  var n = 0;
  return ref.watch(downloadManagerProvider).changes.map((_) => ++n);
});
