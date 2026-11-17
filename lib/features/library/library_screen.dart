import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/library.dart';
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

    final tabs = <_Tab>[
      _Tab('Все', (_) => true),
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
              ),
          ]),
        ),
      ),
    );
  }
}

class _Grid extends ConsumerWidget {
  const _Grid({required this.items, required this.emptyAll});
  final List<LibraryEntry> items;
  final bool emptyAll;

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
    return RefreshIndicator(
      onRefresh: () => ref.read(syncEngineProvider).sync(),
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, MfSpace.huge),
        gridDelegate: coverGridDelegate(context),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final e = items[i];
          final total = e.totalChapters;
          final read = e.lastChapterNumber;
          return MangaTile(
            card: e.toCard(),
            heroPrefix: 'lib',
            badge: e.unreadUpdates > 0 ? '+${e.unreadUpdates}' : null,
            subtitle: [
              e.status.label,
              if (read != null) 'гл. ${read % 1 == 0 ? read.toInt() : read}${total != null ? ' из $total' : ''}',
            ].join(' · '),
            onTap: () => context.push(Routes.title(e.sourceId, e.mangaId)),
            onLongPress: () => showEntryActions(context, ref, e),
          );
        },
      ),
    );
  }
}

/// Small helper text style used by library widgets.
TextStyle mutedCaption(BuildContext context) => MfType.caption.copyWith(color: context.textTertiary);
