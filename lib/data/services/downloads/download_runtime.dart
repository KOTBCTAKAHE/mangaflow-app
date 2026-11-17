import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/database.dart';
import '../../models/settings.dart';
import '../../remote/catalog_api.dart';
import 'download_engine.dart';

/// connectivity_plus → [NetState].
class ConnectivityProbe implements NetworkProbe {
  @override
  Future<NetState> check() async {
    final r = await Connectivity().checkConnectivity();
    if (r.isEmpty || r.every((x) => x == ConnectivityResult.none)) return NetState.none;
    if (r.contains(ConnectivityResult.wifi) || r.contains(ConnectivityResult.ethernet)) return NetState.unmetered;
    return NetState.metered;
  }
}

/// Settings for isolates that can't use Riverpod: re-read from SharedPreferences periodically.
class PrefsSettings {
  PrefsSettings(this._prefs) {
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _prefs.reload();
      _load();
    });
  }

  final SharedPreferences _prefs;
  late AppSettings value;
  Timer? _timer;

  void _load() {
    final raw = _prefs.getString('app_settings_v1');
    value = raw == null
        ? AppSettings(apiBaseUrl: AppConfig.defaultApiBaseUrl, updatedAt: DateTime.now())
        : AppSettings.fromJson((jsonDecode(raw) as Map).cast(), fallbackUrl: AppConfig.defaultApiBaseUrl);
  }

  void dispose() => _timer?.cancel();
}

Dio pageHttpClient() => Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      headers: {'Accept': 'image/avif,image/webp,image/*,*/*;q=0.8'},
    ));

/// Builds an engine wired to the backend, for any isolate.
DownloadEngine buildEngine({
  required Database db,
  required String owner,
  required AppSettings Function() settings,
  void Function(EngineEvent)? onProgress,
}) {
  final client = ApiClient(baseUrl: settings().apiBaseUrl);
  final api = CatalogApi(client);
  return DownloadEngine(
    db: db,
    owner: owner,
    http: pageHttpClient(),
    net: ConnectivityProbe(),
    onProgress: onProgress,
    settings: () {
      final s = settings();
      if (client.baseUrl != '${s.apiBaseUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1') client.baseUrl = s.apiBaseUrl;
      return EngineSettings(wifiOnly: s.downloadWifiOnly, imageWidth: s.imageQuality.width);
    },
    pagesFor: (sourceId, chapterId, width) => api.pages(sourceId, chapterId, width: width),
  );
}

// =====================================================================================
// Android foreground service: keeps the process alive (wake + Wi-Fi locks) with a
// progress notification, survives the app being swiped away and restarts on boot.
// =====================================================================================

const _serviceId = 4711;

abstract final class DownloadService {
  static bool get supported => Platform.isAndroid;

  static void init() {
    if (!supported) return;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'chapter_downloads',
        channelName: 'Загрузка глав',
        channelDescription: 'Прогресс офлайн-загрузок',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(60000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  static Future<bool> isRunning() async => supported && await FlutterForegroundTask.isRunningService;

  /// Starts the service if needed; false when Android refused (caller falls back to in-process).
  static Future<bool> ensureStarted() async {
    if (!supported) return false;
    try {
      if (await FlutterForegroundTask.isRunningService) return true;
      final r = await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: [ForegroundServiceTypes.specialUse],
        notificationTitle: 'Загрузка глав',
        notificationText: 'Подготовка…',
        notificationButtons: [const NotificationButton(id: 'pause', text: 'Пауза')],
        callback: downloadServiceCallback,
      );
      return r is ServiceRequestSuccess;
    } catch (_) {
      return false;
    }
  }

  static void addListener(void Function(Object data) cb) {
    if (supported) FlutterForegroundTask.addTaskDataCallback(cb);
  }

  static void removeListener(void Function(Object data) cb) {
    if (supported) FlutterForegroundTask.removeTaskDataCallback(cb);
  }
}

@pragma('vm:entry-point')
void downloadServiceCallback() {
  FlutterForegroundTask.setTaskHandler(DownloadTaskHandler());
}

class DownloadTaskHandler extends TaskHandler {
  DownloadEngine? _engine;
  PrefsSettings? _settings;
  Database? _db;
  bool _destroyed = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  EngineEvent? _last;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _db = (await AppDatabase.open()).db; // shared native handle: never closed here
    _settings = PrefsSettings(await SharedPreferences.getInstance());
    _engine = buildEngine(db: _db!, owner: 'service', settings: () => _settings!.value, onProgress: _onProgress);
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_destroyed) {
      final r = await _engine!.run();
      if (r == RunResult.leaseBusy) {
        await Future<void>.delayed(const Duration(seconds: 20));
        continue;
      }
      break; // idle or stopped
    }
    if (!_destroyed) {
      await _notify(force: true, finished: true);
      await FlutterForegroundTask.stopService();
    }
  }

  void _onProgress(EngineEvent e) {
    _last = e;
    FlutterForegroundTask.sendDataToMain('changed');
    unawaited(_notify());
  }

  Future<void> _notify({bool force = false, bool finished = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastNotify) < const Duration(milliseconds: 1500)) return;
    _lastNotify = now;
    final db = _db;
    if (db == null) return;
    final rows = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN status IN ('queued','retrying','downloading') THEN 1 ELSE 0 END) AS pending,
        SUM(CASE WHEN status = 'retrying' THEN 1 ELSE 0 END) AS retrying,
        SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
      FROM downloads''');
    final pending = (rows.first['pending'] as int?) ?? 0;
    final retrying = (rows.first['retrying'] as int?) ?? 0;
    final failed = (rows.first['failed'] as int?) ?? 0;
    final e = _last;
    final String title;
    final String text;
    if (finished) {
      title = failed > 0 ? 'Загрузка завершена с ошибками' : 'Все главы загружены';
      text = failed > 0 ? 'Не удалось: $failed. Откройте «Загрузки», чтобы повторить.' : 'Можно читать без интернета';
    } else if (e?.state == 'waiting_network') {
      title = 'Ожидание сети';
      text = 'Осталось глав: $pending. Загрузка продолжится автоматически.';
    } else if (e?.state == 'waiting_wifi') {
      title = 'Ожидание Wi-Fi';
      text = 'Осталось глав: $pending (включено «только по Wi-Fi»).';
    } else if (e?.state == 'waiting_retry') {
      title = 'Повтор позже';
      text = 'Осталось глав: $pending, из них ждут повтора: $retrying.';
    } else {
      title = 'Загрузка глав · осталось $pending';
      text = [e?.mangaTitle, e?.chapterTitle].whereType<String>().join(' · ');
    }
    await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // heartbeat: refresh the notification even if nothing changed
    unawaited(_notify(force: true));
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'pause') unawaited(_pauseAll());
  }

  Future<void> _pauseAll() async {
    await _db?.update('downloads', {'status': 'paused'}, where: "status IN ('queued','retrying','downloading')");
    _engine?.stop();
    FlutterForegroundTask.sendDataToMain('changed');
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/downloads');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    _engine?.stop();
    _settings?.dispose();
  }
}
