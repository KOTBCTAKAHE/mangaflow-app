import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/services/download_manager.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

final _downloadsProvider = FutureProvider.autoDispose<(List<DownloadTask>, int)>((ref) async {
  ref.watch(downloadsChangesProvider);
  final m = ref.watch(downloadManagerProvider);
  return (await m.all(), await m.totalBytes());
});

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
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'pause', child: Text('Приостановить все')),
            PopupMenuItem(value: 'resume', child: Text('Продолжить все')),
            PopupMenuItem(value: 'retry', child: Text('Повторить неудачные')),
          ],
        ),
      ]),
      body: AsyncBody(
        value: data,
        data: (d) {
          final (tasks, bytes) = d;
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
          return ListView(padding: const EdgeInsets.only(bottom: MfSpace.huge), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, MfSpace.md),
              child: Text('${tasks.where((t) => t.status == DownloadStatus.completed).length} глав · ${formatBytes(bytes)}',
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
      leading: MangaCover(url: first.coverUrl, width: 40, radius: MfRadius.xs, thumbWidth: 160),
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
              DownloadStatus.downloading => Padding(
                  padding: const EdgeInsets.only(top: MfSpace.xs),
                  child: LinearProgressIndicator(value: t.pageCount == 0 ? null : t.progress),
                ),
            },
            onTap: t.status == DownloadStatus.completed
                ? () => context.push(Routes.reader(t.sourceId, t.mangaId, t.chapterId))
                : null,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (t.status == DownloadStatus.failed || t.status == DownloadStatus.paused)
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
