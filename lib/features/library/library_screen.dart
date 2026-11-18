import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
import '../../data/models/settings.dart';
import '../../widgets/effects.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import 'library_actions.dart';

enum LibrarySort {
  lastRead('Недавно читал'),
  updated('Изменённые'),
  added('Недавно добавленные'),
  title('По названию'),
  unread('С новыми главами');

  const LibrarySort(this.label);
  final String label;
}

final librarySortProvider = StateProvider<LibrarySort>((_) => LibrarySort.lastRead);
final libraryQueryProvider = StateProvider<String>((_) => '');

class _Tab {
  const _Tab(this.label, this.test);
  final String label;
  final bool Function(LibraryEntry e) test;
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  bool _searching = false;

  List<LibraryEntry> _sorted(List<LibraryEntry> items, LibrarySort sort, String q) {
    final query = q.trim().toLowerCase();
    final list = [for (final e in items) if (query.isEmpty || e.title.toLowerCase().contains(query)) e];
    int byDate(DateTime? a, DateTime? b) => (b ?? DateTime(0)).compareTo(a ?? DateTime(0));
    switch (sort) {
      case LibrarySort.lastRead:
        list.sort((a, b) => byDate(a.lastReadAt ?? a.addedAt, b.lastReadAt ?? b.addedAt));
      case LibrarySort.updated:
        list.sort((a, b) => byDate(a.updatedAt, b.updatedAt));
      case LibrarySort.added:
        list.sort((a, b) => byDate(a.addedAt, b.addedAt));
      case LibrarySort.title:
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case LibrarySort.unread:
        list.sort((a, b) => b.unreadUpdates != a.unreadUpdates
            ? b.unreadUpdates.compareTo(a.unreadUpdates)
            : byDate(a.lastReadAt, b.lastReadAt));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(libraryEntriesProvider);
    final collections = ref.watch(collectionsProvider).valueOrNull ?? const <Collection>[];
    final sort = ref.watch(librarySortProvider);
    final query = ref.watch(libraryQueryProvider);
    final view = ref.watch(settingsProvider.select((x) => x.libraryView));

    final all = entries.valueOrNull ?? const <LibraryEntry>[];
    final monthAgo = DateTime.now().subtract(const Duration(days: 30));
    bool fresh(LibraryEntry e) => e.unreadUpdates > 0;
    bool almost(LibraryEntry e) {
      final r = e.lastChapterNumber, t = e.totalChapters;
      if (r == null || t == null || t < 5) return false;
      return r < t && (r / t >= 0.8 || t - r <= 3);
    }

    bool abandoned(LibraryEntry e) =>
        e.status == LibraryStatus.reading && (e.lastReadAt ?? e.addedAt).isBefore(monthAgo);
    final tabs = <_Tab>[
      _Tab('Все', (_) => true),
      // smart shelves — shown only when they have something
      if (all.any(fresh)) _Tab('Вышли новые главы', fresh),
      if (all.any(almost)) _Tab('Почти дочитано', almost),
      if (all.any(abandoned)) _Tab('Брошено > месяца', abandoned),
      _Tab('Избранное', (e) => e.isFavorite),
      for (final s in LibraryStatus.values) _Tab(s.label, (e) => e.status == s),
      for (final c in collections) _Tab(c.name, (e) => e.collectionIds.contains(c.id)),
    ];

    return DefaultTabController(
      key: ValueKey(tabs.length),
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: MfSpace.gutter,
          title: _searching
              ? TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Поиск в библиотеке', isDense: true),
                  onChanged: (v) => ref.read(libraryQueryProvider.notifier).state = v,
                )
              : const Text('Библиотека'),
          actions: [
            IconButton(
              tooltip: _searching ? 'Закрыть поиск' : 'Поиск',
              icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
              onPressed: () {
                setState(() => _searching = !_searching);
                if (!_searching) ref.read(libraryQueryProvider.notifier).state = '';
              },
            ),
            IconButton(
              tooltip: 'Вид: ${view.label}',
              icon: Icon(switch (view) {
                LibraryView.grid => Icons.grid_view_rounded,
                LibraryView.compact => Icons.apps_rounded,
                LibraryView.list => Icons.view_agenda_outlined,
              }),
              onPressed: () {
                final next = LibraryView.values[(view.index + 1) % LibraryView.values.length];
                ref.read(settingsProvider.notifier).update((x) => x.copyWith(libraryView: next));
              },
            ),
            PopupMenuButton<LibrarySort>(
              tooltip: 'Сортировка',
              icon: const Icon(Icons.sort_rounded),
              initialValue: sort,
              onSelected: (s) => ref.read(librarySortProvider.notifier).state = s,
              itemBuilder: (_) => [for (final s in LibrarySort.values) PopupMenuItem(value: s, child: Text(s.label))],
            ),
            IconButton(
              tooltip: 'Коллекции',
              icon: const Icon(Icons.folder_copy_outlined),
              onPressed: () => showCollectionsManager(context, ref),
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [for (final t in tabs) Tab(text: t.label)]),
        ),
        body: AsyncBody(
          value: entries,
          onRetry: () => ref.invalidate(libraryEntriesProvider),
          data: (all) => TabBarView(children: [
            for (final t in tabs)
              _Grid(
                items: _sorted(all.where(t.test).toList(), sort, query),
                emptyAll: all.isEmpty,
                view: view,
              ),
          ]),
        ),
      ),
    );
  }
}

class _Grid extends ConsumerWidget {
  const _Grid({required this.items, required this.emptyAll, required this.view});
  final List<LibraryEntry> items;
  final bool emptyAll;
  final LibraryView view;

  static String? _chapterLabel(LibraryEntry e) {
    final read = e.lastChapterNumber;
    if (read == null) return null;
    final total = e.totalChapters;
    return 'гл. ${read % 1 == 0 ? read.toInt() : read}${total != null ? ' из $total' : ''}';
  }

  static double? _progress(LibraryEntry e) {
    final read = e.lastChapterNumber, total = e.totalChapters;
    if (read == null || total == null || total <= 0) return null;
    return (read / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) {
      return emptyAll
          ? EmptyState(
              icon: Icons.collections_bookmark_outlined,
              title: 'Библиотека пуста',
              message: 'Добавляйте тайтлы кнопкой «В библиотеку» — они будут доступны и офлайн.',
              action: FilledButton(onPressed: () => context.go('/discover'), child: const Text('Найти мангу')),
            )
          : const EmptyState(icon: Icons.filter_list_off_rounded, title: 'Здесь пока ничего нет');
    }
    final pad = EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, bottomInset(context, MfSpace.huge));
    void open(LibraryEntry e) => context.push(Routes.title(e.sourceId, e.mangaId));

    final Widget body = switch (view) {
      LibraryView.list => ListView.separated(
          padding: pad,
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(height: MfSpace.md),
          itemBuilder: (context, i) {
            final e = items[i];
            return Appear(
              index: i,
              child: _ListRow(
                entry: e,
                chapter: _chapterLabel(e),
                progress: _progress(e),
                onTap: () => open(e),
                onLongPress: () => showEntryActions(context, ref, e),
              ),
            );
          },
        ),
      _ => GridView.builder(
          padding: pad,
          gridDelegate: view == LibraryView.compact
              ? coverGridDelegate(context, maxCover: 112, subtitle: false)
              : coverGridDelegate(context),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final e = items[i];
            final compact = view == LibraryView.compact;
            return MangaTile(
              card: e.toCard(),
              heroPrefix: 'lib',
              index: i,
              showKind: !compact,
              badge: e.unreadUpdates > 0 ? '+${e.unreadUpdates}' : null,
              progress: _progress(e),
              subtitle: compact ? null : [e.status.label, if (_chapterLabel(e) != null) _chapterLabel(e)!].join(' · '),
              onTap: () => open(e),
              onLongPress: () => showEntryActions(context, ref, e),
            );
          },
        ),
    };
    return RefreshIndicator(onRefresh: () => ref.read(syncEngineProvider).sync(), child: body);
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.entry, required this.onTap, required this.onLongPress, this.chapter, this.progress});
  final LibraryEntry entry;
  final String? chapter;
  final double? progress;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return PressableScale(
      scale: 0.98,
      child: Material(
        color: context.colors.surfaceContainer,
        borderRadius: BorderRadius.circular(MfRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(MfSpace.sm),
            child: Row(children: [
              MangaCover(url: e.coverUrl, width: 64, radius: MfRadius.sm, heroTag: 'lib-row-${e.key}'),
              const SizedBox(width: MfSpace.md),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: MfType.label.copyWith(color: context.colors.onSurface)),
                    ),
                    if (e.isFavorite) Icon(Icons.favorite_rounded, size: 16, color: MfColors.accent),
                  ]),
                  const SizedBox(height: MfSpace.xs),
                  Text([e.status.label, if (chapter != null) chapter!].join(' · '), style: mutedCaption(context)),
                  if (progress != null) ...[
                    const SizedBox(height: MfSpace.sm),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(MfRadius.pill),
                      child: LinearProgressIndicator(value: progress, minHeight: 4, color: MfColors.accent),
                    ),
                  ],
                ]),
              ),
              if (e.unreadUpdates > 0) ...[
                const SizedBox(width: MfSpace.md),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: MfColors.accentSoft, borderRadius: BorderRadius.circular(MfRadius.pill)),
                  child: Text('+${e.unreadUpdates}', style: MfType.caption.copyWith(color: MfColors.accent, fontWeight: FontWeight.w800)),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

/// Small helper text style used by library widgets.
TextStyle mutedCaption(BuildContext context) => MfType.caption.copyWith(color: context.textTertiary);
