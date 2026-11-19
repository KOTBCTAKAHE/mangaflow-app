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
import '../notifications.dart';
import 'download_engine.dart';
import 'download_upscale.dart';

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
  final ping = Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 8)));
  return DownloadEngine(
    reachable: () async {
      final base = settings().apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
      try {
        final r = await ping.get<dynamic>('$base/health/live', options: Options(validateStatus: (_) => true));
        return (r.statusCode ?? 0) > 0 && (r.statusCode ?? 0) < 500;
      } catch (_) {
        return false;
      }
    },
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
    initOptions();
  }

  /// Service options only (usable from background isolates, e.g. WorkManager).
  static void initOptions() {
    if (!supported) return;
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
  static Future<bool> isRunning() async {
    if (!supported) return false;
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

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
  DownloadUpscaler? _upscaler;
  UpscaleProgress? _up;
  bool _paused = false;
  PrefsSettings? _settings;
  Database? _db;
  bool _destroyed = false;
  bool _upscaling = false;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  EngineEvent? _last;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _db = (await AppDatabase.open()).db; // shared native handle: never closed here
    final sp = await SharedPreferences.getInstance();
    await sp.reload(); // the app may have changed settings right before starting us
    _settings = PrefsSettings(sp);
    _engine = buildEngine(db: _db!, owner: 'service', settings: () => _settings!.value, onProgress: _onProgress);
    _upscaler = DownloadUpscaler(
      db: _db!,
      settings: () => _settings!.value,
      prefs: await SharedPreferences.getInstance(),
      onProgress: (p) {
        _up = p;
        unawaited(_notify());
      },
      shouldYield: () async => _destroyed || await _pendingDownloads() > 0,
    )..force = sp.getBool(upscaleForcePref) ?? false;
    await sp.remove(upscaleForcePref);
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_destroyed) {
      final r = await _engine!.run();
      if (r == RunResult.leaseBusy) {
        await Future<void>.delayed(const Duration(seconds: 20));
        continue;
      }
      if (_destroyed || _paused) break;
      // Downloads are done: enhance the downloaded pages with AI (overnight mode).
      _upscaling = true;
      await _notify(force: true);
      await _upscaler!.run();
      _upscaling = false;
      _up = null;
      if (!_destroyed && !_paused && await _pendingDownloads() > 0) continue; // new chapters were queued meanwhile
      break; // idle or stopped
    }
    if (!_destroyed) {
      await _notify(force: true, finished: true);
      // the service notification disappears with the service: leave a normal one with the result
      final up = _upscaler;
      if (up != null && up.problem != null) {
        final why = switch (up.problem) {
          'unsupported_platform' => 'нейросеть недоступна на этом устройстве',
          'out_of_memory' => 'не хватило памяти — выберите качество «Быстро»',
          _ => up.problem!,
        };
        await ChapterNotifier.instance.showInfo(7001, 'Улучшение страниц не удалось', why);
      } else if (up != null && up.processed > 0) {
        await ChapterNotifier.instance.showInfo(7001, 'Страницы улучшены (ИИ)',
            'Готово: ${up.processed} стр.${up.skippedSharp > 0 ? ' Уже чётких пропущено: ${up.skippedSharp}.' : ''}');
      } else if (up != null && up.skippedSharp > 0) {
        await ChapterNotifier.instance.showInfo(7001, 'Страницы уже чёткие',
            '${up.skippedSharp} стр. не меньше ширины экрана — нейросеть их пропустила. Чтобы улучшить всё равно, нажмите «Улучшить скачанные (ИИ)» ещё раз.');
      }
      await FlutterForegroundTask.stopService();
    }
  }

  Future<int> _pendingDownloads() async {
    final rows = await _db!.rawQuery("SELECT COUNT(*) AS n FROM downloads WHERE status IN ('queued','retrying','downloading')");
    return (rows.first['n'] as int?) ?? 0;
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
    final up = _up;
    if (!finished && up == null && _upscaling && pending == 0) {
      title = 'Улучшение страниц (ИИ)';
      text = 'Подготовка нейросети…';
    } else if (!finished && up != null && pending == 0) {
      title = 'Улучшение страниц (ИИ) · глав осталось ${up.chaptersLeft}';
      text = '${[up.mangaTitle, up.chapterTitle].where((s) => s.isNotEmpty).join(' · ')} · стр. ${up.page}/${up.pages}';
    } else if (finished) {
      final enhanced = (_upscaler?.processed ?? 0) > 0;
      title = failed > 0
          ? 'Загрузка завершена с ошибками'
          : (enhanced ? 'Главы загружены и улучшены' : 'Все главы загружены');
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
  void onReceiveData(Object data) {
    // «Улучшить скачанные» pressed while we are already running
    if (data == 'upscale') {
      unawaited(() async {
        final sp = await SharedPreferences.getInstance();
        await sp.reload();
        if (sp.getBool(upscaleForcePref) ?? false) _upscaler?.force = true;
        await sp.remove(upscaleForcePref);
      }());
    }
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
    _paused = true;
    _upscaler?.stop();
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
    _upscaler?.stop();
    _settings?.dispose();
  }
}
