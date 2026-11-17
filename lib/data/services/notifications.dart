import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/reading.dart';

/// Local notifications for new chapters.
class ChapterNotifier {
  ChapterNotifier._();
  static final instance = ChapterNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channel = AndroidNotificationChannel(
    'new_chapters',
    'Новые главы',
    description: 'Уведомления о новых главах тайтлов из библиотеки',
    importance: Importance.defaultImportance,
  );

  Future<void> init() async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
    );
    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);
    _ready = true;
  }

  Future<bool> requestPermission() async {
    await init();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await ios?.requestPermissions(alert: true, badge: true, sound: true);
    return granted ?? iosGranted ?? true;
  }

  Future<void> showNewChapters(List<ChapterUpdate> updates) async {
    if (updates.isEmpty) return;
    await init();
    final byTitle = <String, List<ChapterUpdate>>{};
    for (final u in updates) {
      byTitle.putIfAbsent('${u.sourceId}:${u.mangaId}', () => []).add(u);
    }
    var id = 1000;
    for (final group in byTitle.values.take(5)) {
      final first = group.first;
      final body = group.length == 1 ? first.chapterTitle : '${group.length} новых глав · ${group.first.chapterTitle}';
      await _plugin.show(
        id++,
        first.mangaTitle.isEmpty ? 'Новая глава' : first.mangaTitle,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(_channel.id, _channel.name,
              channelDescription: _channel.description, groupKey: 'mangaflow.updates', category: AndroidNotificationCategory.social),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: '${first.sourceId}|${first.mangaId}',
      );
    }
  }
}
