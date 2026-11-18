import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/local/bookmarks_dao.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';

class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(bookmarksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Закладки')),
      body: AsyncBody(
        value: list,
        onRetry: () => ref.invalidate(bookmarksProvider),
        data: (items) {
          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.bookmarks_outlined,
              title: 'Закладок пока нет',
              message: 'В читалке нажмите на значок закладки вверху, чтобы запомнить страницу и добавить заметку.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(MfSpace.gutter),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: MfSpace.sm),
            itemBuilder: (context, i) {
              final b = items[i];
              return Dismissible(
                key: ValueKey(b.id),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: MfSpace.xl),
                  decoration: BoxDecoration(color: MfColors.danger, borderRadius: BorderRadius.circular(MfRadius.lg)),
                  child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                ),
                onDismissed: (_) async {
                  await ref.read(bookmarksDaoProvider).delete(b.id);
                  ref.read(dataVersionProvider.notifier).state++;
                },
                child: _BookmarkTile(b: b),
              );
            },
          );
        },
      ),
    );
  }
}

class _BookmarkTile extends StatelessWidget {
  const _BookmarkTile({required this.b});
  final Bookmark b;

  @override
  Widget build(BuildContext context) => Material(
        color: context.colors.surfaceContainer,
        borderRadius: BorderRadius.circular(MfRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push(Routes.reader(b.sourceId, b.mangaId, b.chapterId, page: b.pageIndex)),
          child: Padding(
            padding: const EdgeInsets.all(MfSpace.sm),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MangaCover(url: b.coverUrl, width: 52, radius: MfRadius.sm, shadow: false),
              const SizedBox(width: MfSpace.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(b.mangaTitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: MfType.label.copyWith(color: context.colors.onSurface)),
                  Text('${b.chapterTitle} · стр. ${b.pageIndex + 1}', style: context.text.bodySmall),
                  if (b.note.isNotEmpty) ...[
                    const SizedBox(height: MfSpace.xs),
                    Text('«${b.note}»', maxLines: 3, overflow: TextOverflow.ellipsis, style: context.text.bodyMedium),
                  ],
                ]),
              ),
              Icon(Icons.bookmark_rounded, color: MfColors.accent, size: 20),
            ]),
          ),
        ),
      );
}
