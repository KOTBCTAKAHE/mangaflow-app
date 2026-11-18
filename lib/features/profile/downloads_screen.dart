import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/settings.dart';
import '../../data/services/download_manager.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import '../../data/services/background_guide.dart';
import '../downloads_support.dart';
import '../../data/services/downloads/download_runtime.dart';

final _downloadsProvider = FutureProvider.autoDispose<(List<DownloadTask>, int, DownloadsState, bool)>((ref) async {
  ref.watch(downloadsChangesProvider);
  final m = ref.watch(downloadManagerProvider);
  return (await m.all(), await m.totalBytes(), await m.state(), await isBatteryUnrestricted());
});

final _vendorGuideProvider = FutureProvider.autoDispose<VendorGuide?>((_) => VendorGuide.forThisDevice());

String _hhmm(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(_downloadsProvider);
    final m = ref.read(downloadManagerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Загрузки'), actions: [
        PopupMenuButton<String>(
          onSelected: (v) async {
            switch (v) {
              case 'pause':
                await m.pauseAll();
              case 'resume':
                await m.resumeAll();
              case 'retry':
                await m.retryAllFailed();
              case 'upscale':
                final s = ref.read(settingsProvider);
                if (s.upscaleMode == UpscaleMode.off || !s.upscaleDownloads) {
                  await ref.read(settingsProvider.notifier).update((x) => x.copyWith(
                        upscaleDownloads: true,
                        upscaleMode: x.upscaleMode == UpscaleMode.off ? UpscaleMode.auto : x.upscaleMode,
                      ));
                }
                final ok = await DownloadService.ensureStarted();
                if (context.mounted) {
                  showSnack(context, ok
                      ? 'Улучшаю скачанные главы в фоне — прогресс в уведомлении'
                      : 'Не удалось запустить фоновую службу');
                }
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'pause', child: Text('Приостановить все')),
            PopupMenuItem(value: 'resume', child: Text('Продолжить все')),
            PopupMenuItem(value: 'retry', child: Text('Повторить неудачные')),
            PopupMenuItem(value: 'upscale', child: Text('Улучшить скачанные (ИИ)')),
          ],
        ),
      ]),
      body: AsyncBody(
        value: data,
        data: (d) {
          final (tasks, bytes, state, batteryOk) = d;
          if (tasks.isEmpty) {
            return const EmptyState(
              icon: Icons.download_for_offline_outlined,
              title: 'Нет загрузок',
              message: 'Скачивайте главы на странице тайтла — они откроются без интернета.',
            );
          }
          final groups = <String, List<DownloadTask>>{};
          for (final t in tasks) {
            groups.putIfAbsent('${t.sourceId}|${t.mangaId}', () => []).add(t);
          }
          final active = tasks.where((t) => t.isActive).length;
          final failed = tasks.where((t) => t.status == DownloadStatus.failed).length;
          return ListView(padding: const EdgeInsets.only(bottom: MfSpace.huge), children: [
            if (active > 0 && state == DownloadsState.waitingNetwork)
              const _Banner(icon: Icons.wifi_off_rounded, text: 'Нет сети. Загрузка продолжится сама, как только интернет появится.'),
            if (active > 0 && state == DownloadsState.waitingWifi)
              const _Banner(icon: Icons.wifi_rounded, text: 'Ожидание Wi-Fi: включено «Загружать только по Wi-Fi».'),
            if (active > 0 && state == DownloadsState.waitingRetry)
              _Banner(
                icon: Icons.schedule_rounded,
                text: 'Источник или сеть нестабильны — главы будут повторены автоматически.',
                action: TextButton(onPressed: m.retryAllFailed, child: const Text('Сейчас')),
              ),
            if (active > 0 && !batteryOk)
              _Banner(
                icon: Icons.battery_alert_rounded,
                text: 'Экономия батареи может остановить загрузку ночью.',
                action: TextButton(
                  onPressed: () async {
                    await ensureBackgroundAllowed(context, ref, force: true);
                    ref.invalidate(_downloadsProvider);
                  },
                  child: const Text('Разрешить'),
                ),
              ),
            if (ref.watch(_vendorGuideProvider).valueOrNull case final guide?)
              _Banner(
                icon: Icons.phone_android_rounded,
                text: '${guide.vendor}: разрешите фоновую работу, иначе загрузка встанет при выключенном экране.',
                action: TextButton(onPressed: () => showVendorGuide(context, guide), child: const Text('Как')),
              ),
            if (failed > 0)
              _Banner(
                icon: Icons.error_outline_rounded,
                text: 'Не удалось скачать: $failed.',
                action: TextButton(onPressed: m.retryAllFailed, child: const Text('Повторить все')),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, MfSpace.md),
              child: Text(
                  '${tasks.where((t) => t.status == DownloadStatus.completed).length} глав · ${formatBytes(bytes)}'
                  '${active > 0 ? ' · в очереди $active' : ''}',
                  style: context.text.bodySmall),
            ),
            for (final g in groups.values) _Group(tasks: g),
          ]);
        },
      ),
    );
  }
}

class _Group extends ConsumerWidget {
  const _Group({required this.tasks});
  final List<DownloadTask> tasks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = tasks.first;
    final done = tasks.where((t) => t.status == DownloadStatus.completed).length;
    final m = ref.read(downloadManagerProvider);
    return ExpansionTile(
      leading: MangaCover(url: first.coverUrl, width: 40, radius: MfRadius.xs),
      title: Text(first.mangaTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$done из ${tasks.length} глав'),
      children: [
        ListTile(
          leading: const Icon(Icons.open_in_new_rounded),
          title: const Text('Открыть тайтл'),
          onTap: () => context.push(Routes.title(first.sourceId, first.mangaId)),
        ),
        for (final t in tasks)
          ListTile(
            dense: true,
            title: Text(t.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: switch (t.status) {
              DownloadStatus.completed => Text(formatBytes(t.sizeBytes)),
              DownloadStatus.failed => Text(t.error ?? 'Ошибка', style: const TextStyle(color: MfColors.danger)),
              DownloadStatus.paused => const Text('Пауза'),
              DownloadStatus.queued => const Text('В очереди'),
              DownloadStatus.retrying => Text(
                  'Повтор${t.nextAttemptAt != null ? ' в ${_hhmm(t.nextAttemptAt!)}' : ''} · попытка ${t.attempts}'
                  '${t.error != null ? ' · ${t.error}' : ''}',
                  maxLines: 2,
                  style: const TextStyle(color: MfColors.warning)),
              DownloadStatus.downloading => Padding(
                  padding: const EdgeInsets.only(top: MfSpace.xs),
                  child: LinearProgressIndicator(value: t.pageCount == 0 ? null : t.progress),
                ),
            },
            onTap: t.status == DownloadStatus.completed
                ? () => context.push(Routes.reader(t.sourceId, t.mangaId, t.chapterId))
                : null,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (t.status == DownloadStatus.failed || t.status == DownloadStatus.paused || t.status == DownloadStatus.retrying)
                IconButton(tooltip: 'Повторить', icon: const Icon(Icons.refresh_rounded), onPressed: () => m.retry(t)),
              IconButton(
                tooltip: 'Удалить',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => m.delete(t.sourceId, t.chapterId),
              ),
            ]),
          ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text, this.action});
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, 0),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.lg, vertical: MfSpace.sm),
            child: Row(children: [
              Icon(icon, color: MfColors.accent),
              const SizedBox(width: MfSpace.md),
              Expanded(child: Text(text, style: context.text.bodySmall)),
              if (action != null) action!,
            ]),
          ),
        ),
      );
}
