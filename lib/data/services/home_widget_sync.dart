import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/router.dart';
import '../../widgets/net_image.dart';
import '../models/library.dart';
import '../models/reading.dart';

/// Feeds the Android home-screen widget "Продолжить чтение" (ContinueWidgetProvider.kt).
abstract final class HomeWidgetSync {
  static const _ch = MethodChannel('mangaflow/widget');
  static String? _lastKey;

  static Future<void> update(SharedPreferences prefs, ContinueItem? item) async {
    if (!Platform.isAndroid) return;
    final key = item == null ? 'none' : '${item.sourceId}|${item.chapterId}|${(item.fraction * 100).round()}';
    if (key == _lastKey) return;
    _lastKey = key;
    try {
      if (item == null) {
        for (final k in const ['widget_title', 'widget_chapter', 'widget_progress', 'widget_cover', 'widget_route']) {
          await prefs.remove(k);
        }
      } else {
        await prefs.setString('widget_title', item.title);
        await prefs.setString('widget_chapter', item.chapterTitle);
        await prefs.setInt('widget_progress', (item.fraction * 100).round());
        await prefs.setString('widget_route', Routes.reader(item.sourceId, item.mangaId, item.chapterId));
        if (item.coverUrl.isNotEmpty) {
          try {
            final src = await DefaultCacheManager().getSingleFile(withWidth(item.coverUrl, 320));
            final dst = File('${(await getApplicationSupportDirectory()).path}/widget_cover.img');
            await src.copy(dst.path);
            await prefs.setString('widget_cover', dst.path);
          } catch (_) {}
        }
      }
      await _ch.invokeMethod<void>('update');
    } catch (_) {}
  }

  static String? _lastLibKey;

  /// «Библиотека» widget: titles with new chapters first, then the most recently read.
  /// Safe from the background isolate (update check): it writes prefs and broadcasts a refresh.
  static Future<void> updateLibrary(SharedPreferences prefs, List<LibraryEntry> entries) async {
    if (!Platform.isAndroid) return;
    final live = [for (final e in entries) if (!e.deleted) e];
    DateTime at(LibraryEntry e) => e.lastReadAt ?? e.updatedAt;
    live.sort((a, b) {
      final na = a.unreadUpdates > 0, nb = b.unreadUpdates > 0;
      if (na != nb) return na ? -1 : 1;
      return at(b).compareTo(at(a));
    });
    final top = live.take(4).toList();
    final fresh = live.fold<int>(0, (n, e) => n + e.unreadUpdates);
    final key = '$fresh|${[for (final e in top) '${e.sourceId}:${e.mangaId}:${e.unreadUpdates}:${e.coverUrl.hashCode}'].join(',')}';
    if (key == _lastLibKey) return;
    _lastLibKey = key;
    try {
      await prefs.setInt('widget_lib_count', top.length);
      await prefs.setInt('widget_lib_new', fresh);
      final dir = (await getApplicationSupportDirectory()).path;
      for (var i = 0; i < top.length; i++) {
        final e = top[i];
        await prefs.setString('widget_lib_${i}_title', e.title);
        await prefs.setString('widget_lib_${i}_badge', e.unreadUpdates > 0 ? '+${e.unreadUpdates}' : '');
        await prefs.setString('widget_lib_${i}_route', Routes.title(e.sourceId, e.mangaId));
        await prefs.remove('widget_lib_${i}_cover');
        if (e.coverUrl.isNotEmpty) {
          try {
            final src = await DefaultCacheManager().getSingleFile(withWidth(e.coverUrl, 240));
            final dst = File('$dir/widget_lib_$i.img');
            await src.copy(dst.path);
            await prefs.setString('widget_lib_${i}_cover', dst.path);
          } catch (_) {}
        }
      }
      await refresh();
    } catch (_) {}
  }

  /// Redraw both widgets. A broadcast, so it also works without the activity (background checks).
  static Future<void> refresh() async {
    if (!Platform.isAndroid) return;
    try {
      await const AndroidIntent(
        action: 'com.mangaflow.mangaflow.WIDGET_REFRESH',
        package: 'com.mangaflow.mangaflow',
        componentName: 'com.mangaflow.mangaflow.LibraryWidgetProvider',
      ).sendBroadcast();
    } catch (_) {
      try {
        await _ch.invokeMethod<void>('update');
      } catch (_) {}
    }
  }

  /// Asks the launcher to place a widget ('continue' | 'library'). false: not supported here.
  static Future<bool> pin(String kind) async {
    if (!Platform.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('pin', kind) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Taps on the widget: the route to open (cold start + while running).
  static Future<void> listen(void Function(String route) open) async {
    if (!Platform.isAndroid) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'open' && call.arguments is String) open(call.arguments as String);
    });
    try {
      final initial = await _ch.invokeMethod<String>('initialRoute');
      if (initial != null) open(initial);
    } catch (_) {}
  }
}
