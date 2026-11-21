import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/local/bookmarks_dao.dart';
import '../../widgets/states.dart';
import 'reader_controller.dart';

/// Bookmarks of the open chapter (for the filled/empty icon in the reader).
final chapterBookmarksProvider = FutureProvider.autoDispose.family<Set<String>, (String, String)>((ref, k) {
  ref.watch(dataVersionProvider);
  return ref.watch(bookmarksDaoProvider).idsForChapter(k.$1, k.$2);
});

/// Add / edit / remove the bookmark of the current page, with a note.
Future<void> showBookmarkSheet(BuildContext context, WidgetRef ref, ReaderController c) async {
  final seg = c.current;
  final manga = c.manga;
  if (seg == null || manga == null) return;
  final page = c.page.clamp(0, seg.pages.isEmpty ? 0 : seg.pages.length - 1);
  final id = Bookmark.idFor(manga.sourceId, seg.chapter.id, page);
  final dao = ref.read(bookmarksDaoProvider);
  final existing = await dao.get(id);
  if (!context.mounted) return;
  final note = TextEditingController(text: existing?.note ?? '');
  HapticFeedback.selectionClick();
  final result = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => Padding(
      padding: EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MediaQuery.viewInsetsOf(sheet).bottom + MfSpace.lg),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(existing == null ? 'Закладка на странице' : 'Закладка', style: MfType.title.copyWith(color: sheet.colors.onSurface)),
        const SizedBox(height: MfSpace.xs),
        Text('${seg.chapter.title} · стр. ${page + 1}', style: sheet.text.bodySmall),
        const SizedBox(height: MfSpace.lg),
        TextField(
          controller: note,
          autofocus: existing == null,
          minLines: 2,
          maxLines: 5,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Заметка (необязательно): «тут раскрыли тайну», «любимый разворот»…'),
        ),
        const SizedBox(height: MfSpace.lg),
        Row(children: [
          if (existing != null)
            TextButton.icon(
              onPressed: () => Navigator.pop(sheet, 'delete'),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('Удалить'),
              style: TextButton.styleFrom(foregroundColor: MfColors.danger),
            ),
          const Spacer(),
          FilledButton.icon(
            onPressed: () => Navigator.pop(sheet, 'save'),
            icon: const Icon(Icons.bookmark_rounded),
            label: const Text('Сохранить'),
          ),
        ]),
      ]),
    ),
  );
  if (result == 'save') {
    await dao.put(Bookmark(
      id: id,
      sourceId: manga.sourceId,
      mangaId: manga.id,
      mangaTitle: manga.title,
      coverUrl: manga.coverUrl,
      chapterId: seg.chapter.id,
      chapterTitle: seg.chapter.title,
      chapterNumber: seg.chapter.number,
      pageIndex: page,
      note: note.text.trim(),
      createdAt: existing?.createdAt ?? DateTime.now(),
    ));
  } else if (result == 'delete') {
    await dao.delete(id);
  }
  if (result != null) {
    ref.read(dataVersionProvider.notifier).state++;
    if (context.mounted) showSnack(context, result == 'save' ? 'Закладка сохранена' : 'Закладка удалена');
  }
}
