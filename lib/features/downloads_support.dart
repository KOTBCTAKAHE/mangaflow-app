import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../data/models/manga.dart';
import '../data/services/background_guide.dart';
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
/// to keep a long download alive with the screen off: notifications, battery
/// exemption and — on Vivo/Xiaomi/Huawei/OPPO/Samsung — the vendor's own
/// background whitelist.
Future<void> ensureBackgroundAllowed(BuildContext context, WidgetRef ref, {bool force = false}) async {
  if (!Platform.isAndroid) return;
  final kv = ref.read(kvDaoProvider);
  try {
    if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations &&
        (force || await kv.get('battery_prompted') != '1')) {
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
    }
    final guide = await VendorGuide.forThisDevice();
    if (guide != null && (force || await kv.get('vendor_guide_shown') != '1')) {
      await kv.set('vendor_guide_shown', '1');
      if (context.mounted) await showVendorGuide(context, guide);
    }
  } catch (_) {
    // never block a download because of a permission helper
  }
}

/// Step-by-step sheet with a button that opens the vendor's settings screen.
Future<void> showVendorGuide(BuildContext context, VendorGuide guide) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.lg),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Фоновая загрузка на ${guide.vendor}', style: context.text.titleLarge),
          const SizedBox(height: MfSpace.sm),
          Text(
            'Прошивка ${guide.vendor} останавливает фоновые приложения при выключенном экране, '
            'даже если загрузка идёт с уведомлением. Чтобы главы докачивались ночью:',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: MfSpace.lg),
          for (var i = 0; i < guide.steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: MfSpace.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(
                  radius: 12,
                  backgroundColor: MfColors.accentSoft,
                  child: Text('${i + 1}', style: MfType.caption.copyWith(color: MfColors.accent)),
                ),
                const SizedBox(width: MfSpace.md),
                Expanded(child: Text(guide.steps[i], style: context.text.bodyMedium)),
              ]),
            ),
          const SizedBox(height: MfSpace.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () async {
                await guide.openSettings();
                if (context.mounted) Navigator.pop(context);
              },
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Открыть настройки'),
            ),
          ),
          const SizedBox(height: MfSpace.sm),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () async {
                await VendorGuide.openAppDetails();
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Настройки приложения MangaFlow'),
            ),
          ),
        ]),
      ),
    );

Future<bool> isBatteryUnrestricted() async {
  if (!Platform.isAndroid) return true;
  try {
    return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  } catch (_) {
    return true;
  }
}
