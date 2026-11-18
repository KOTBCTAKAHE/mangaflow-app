import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/reading.dart';
import '../../data/services/background.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

final _updatesProvider = FutureProvider.autoDispose<List<ChapterUpdate>>((ref) {
  ref.watch(dataVersionProvider);
  return ref.watch(updatesDaoProvider).all();
});

class UpdatesScreen extends ConsumerStatefulWidget {
  const UpdatesScreen({super.key});

  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends ConsumerState<UpdatesScreen> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      if (ref.read(authProvider.notifier).isSignedIn) {
        await ref.read(userApiProvider).triggerUpdateCheck();
        await Future<void>.delayed(const Duration(seconds: 4));
        await ref.read(syncEngineProvider).sync();
      } else {
        await BackgroundUpdates.run(db: ref.read(databaseProvider));
      }
      ref.read(dataVersionProvider.notifier).state++;
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.userMessage);
    } catch (e) {
      if (mounted) showSnack(context, 'Не удалось проверить: $e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = ref.watch(_updatesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Новые главы'), actions: [
        IconButton(
          tooltip: 'Отметить все просмотренными',
          icon: const Icon(Icons.done_all_rounded),
          onPressed: () async {
            await ref.read(updatesDaoProvider).markSeen();
            if (ref.read(authProvider.notifier).isSignedIn) {
              await ref.read(userApiProvider).markUpdatesSeen(all: true).catchError((Object _) {});
            }
            for (final e in await ref.read(libraryDaoProvider).all()) {
              if (e.unreadUpdates > 0) await ref.read(libraryDaoProvider).setUnread(e.sourceId, e.mangaId, 0);
            }
            ref.read(dataVersionProvider.notifier).state++;
          },
        ),
      ]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _checking ? null : _check,
        icon: _checking
            ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: MfColors.onAccent))
            : const Icon(Icons.refresh_rounded),
        label: const Text('Проверить'),
        backgroundColor: MfColors.accent,
        foregroundColor: MfColors.onAccent,
      ),
      body: AsyncBody(
        value: items,
        data: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.notifications_none_rounded,
                title: 'Новых глав нет',
                message: 'Тайтлы со статусом «Читаю» и «Планирую» проверяются автоматически.',
              )
            : ListView.builder(
                padding: const EdgeInsets.only(bottom: 96),
                itemCount: list.length,
                itemBuilder: (context, i) {
                  final u = list[i];
                  return ListTile(
                    leading: MangaCover(url: u.coverUrl, width: 44, radius: MfRadius.xs, thumbWidth: 160),
                    title: Text(u.mangaTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: u.seen ? null : const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${u.chapterTitle} · ${formatDate(u.detectedAt)}', maxLines: 1),
                    trailing: u.seen ? null : Icon(Icons.circle, size: 8, color: MfColors.accent),
                    onTap: () => context.push(Routes.reader(u.sourceId, u.mangaId, u.chapterId)),
                    onLongPress: () => context.push(Routes.title(u.sourceId, u.mangaId)),
                  );
                },
              ),
      ),
    );
  }
}
