import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/models/manga.dart';
import '../widgets/states.dart';

/// Single entry point for queueing chapters from the UI: makes sure the system
/// will let downloads run overnight (notification + battery exemption), then enqueues.
Future<void> startDownloads(BuildContext context, WidgetRef ref, MangaDetails manga, List<Chapter> chapters) async {
  if (chapters.isEmpty) return;
  await ensureBackgroundAllowed(context, ref);
  await ref.read(downloadManagerProvider).enqueue(manga: manga, chapters: chapters);
  if (context.mounted && chapters.length > 1) showSnack(context, 'В очереди: ${chapters.length} глав');
}

/// Asks once (and on demand from the Downloads screen) for what Android needs
/// to keep a long download alive with the screen off.
Future<void> ensureBackgroundAllowed(BuildContext context, WidgetRef ref, {bool force = false}) async {
  if (!Platform.isAndroid) return;
  try {
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return;
    final kv = ref.read(kvDaoProvider);
    if (!force && await kv.get('battery_prompted') == '1') return;
    await kv.set('battery_prompted', '1');
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Загрузка в фоне'),
        content: const Text(
          'Чтобы главы докачивались ночью с выключенным экраном, разрешите MangaFlow работать '
          'без ограничений экономии батареи. Иначе Android может остановить загрузку.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Позже')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Разрешить')),
        ],
      ),
    );
    if (ok == true) await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  } catch (_) {
    // never block a download because of a permission helper
  }
}

Future<bool> isBatteryUnrestricted() async {
  if (!Platform.isAndroid) return true;
  try {
    return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  } catch (_) {
    return true;
  }
}
