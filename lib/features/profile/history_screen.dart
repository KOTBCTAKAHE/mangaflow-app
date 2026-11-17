import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/reading.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

final _historyProvider = FutureProvider.autoDispose<List<HistoryItem>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(readingRepositoryProvider).recentHistory(limit: 300);
});

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(_historyProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('История'), actions: [
        IconButton(
          tooltip: 'Очистить историю',
          icon: const Icon(Icons.delete_sweep_outlined),
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Очистить историю?'),
                content: const Text('Прогресс чтения и библиотека сохранятся.'),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Отмена')),
                  FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Очистить')),
                ],
              ),
            );
            if (ok != true) return;
            await ref.read(readingRepositoryProvider).clearHistory();
            if (ref.read(authProvider.notifier).isSignedIn) {
              await ref.read(userApiProvider).clearHistory().catchError((Object _) {});
            }
          },
        ),
      ]),
      body: AsyncBody(
        value: items,
        data: (list) {
          if (list.isEmpty) {
            return const EmptyState(icon: Icons.history_rounded, title: 'История пуста', message: 'Прочитанные главы появятся здесь');
          }
          // one row per title (latest session), grouped by day
          final seen = <String>{};
          final latest = [for (final h in list) if (seen.add('${h.sourceId}:${h.mangaId}')) h];
          String? lastDay;
          final children = <Widget>[];
          for (final h in latest) {
            final day = formatDate(h.readAt);
            if (day != lastDay) {
              lastDay = day;
              children.add(Padding(
                padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.xl, MfSpace.gutter, MfSpace.sm),
                child: Text(day.toUpperCase(), style: context.text.labelSmall),
              ));
            }
            children.add(Dismissible(
              key: ValueKey(h.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: MfSpace.gutter),
                color: MfColors.danger.withValues(alpha: 0.2),
                child: const Icon(Icons.delete_outline_rounded, color: MfColors.danger),
              ),
              onDismissed: (_) async {
                await ref.read(historyDaoProvider).deleteForManga(h.sourceId, h.mangaId);
                ref.read(dataVersionProvider.notifier).state++;
              },
              child: ListTile(
                leading: MangaCover(url: h.coverUrl, width: 44, radius: MfRadius.xs, thumbWidth: 160),
                title: Text(h.mangaTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${h.chapterTitle} · ${formatDuration(h.durationSeconds)}', maxLines: 1),
                trailing: IconButton(
                  tooltip: 'Продолжить',
                  icon: const Icon(Icons.play_arrow_rounded, color: MfColors.accent),
                  onPressed: () => context.push(Routes.reader(h.sourceId, h.mangaId, h.chapterId)),
                ),
                onTap: () => context.push(Routes.title(h.sourceId, h.mangaId)),
              ),
            ));
          }
          return ListView(padding: const EdgeInsets.only(bottom: MfSpace.huge), children: children);
        },
      ),
    );
  }
}
