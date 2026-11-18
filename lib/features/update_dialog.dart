import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/providers.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/tokens.dart';
import '../core/utils/format.dart';
import '../data/services/app_updates.dart';
import '../widgets/states.dart';

final appUpdaterProvider = Provider((ref) => AppUpdater(ref.watch(kvDaoProvider)));

/// Automatic check (throttled to every 12 h) — call after the first frame.
Future<void> autoCheckForUpdates(BuildContext context, WidgetRef ref) async {
  if (!Platform.isAndroid) return;
  try {
    final r = await ref.read(appUpdaterProvider).check();
    if (r != null && context.mounted) await showUpdateDialog(context, ref, r);
  } catch (_) {
    // no network / GitHub rate limit: try again next time
  }
}

/// Manual check from Settings.
Future<void> manualCheckForUpdates(BuildContext context, WidgetRef ref) async {
  try {
    final r = await ref.read(appUpdaterProvider).check(manual: true);
    if (!context.mounted) return;
    if (r == null) {
      final v = await ref.read(appUpdaterProvider).currentVersion();
      if (context.mounted) showSnack(context, 'Установлена последняя версия ($v)');
    } else {
      await showUpdateDialog(context, ref, r);
    }
  } catch (_) {
    if (context.mounted) showSnack(context, 'Не удалось проверить обновления. Проверьте интернет.');
  }
}

Future<void> showUpdateDialog(BuildContext context, WidgetRef ref, AppRelease r) async {
  final current = await ref.read(appUpdaterProvider).currentVersion();
  if (!context.mounted) return;
  final notes = r.notes.length > 900 ? '${r.notes.substring(0, 900)}…' : r.notes;
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Доступна версия ${r.version}'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Установлена $current', style: context.text.bodySmall),
          if (r.apkName != null) ...[
            const SizedBox(height: MfSpace.xs),
            Text('${r.apkName} · ${formatBytes(r.apkSize)}', style: context.text.bodySmall),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: MfSpace.md),
            Text(notes, style: context.text.bodyMedium),
          ],
          const SizedBox(height: MfSpace.md),
          Text('Установите поверх текущей версии — библиотека и прогресс сохранятся.',
              style: context.text.bodySmall?.copyWith(color: MfColors.accent)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, 'skip'), child: const Text('Пропустить')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Позже')),
        FilledButton(onPressed: () => Navigator.pop(context, 'download'), child: const Text('Скачать')),
      ],
    ),
  );
  if (action == 'skip') await ref.read(appUpdaterProvider).skip(r.version);
  if (action == 'download') {
    final url = Uri.parse(r.apkUrl ?? r.pageUrl);
    final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) showSnack(context, 'Откройте ${r.pageUrl} в браузере');
  }
}
