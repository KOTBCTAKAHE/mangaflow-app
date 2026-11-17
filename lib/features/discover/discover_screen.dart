import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import '../home/home_screen.dart' show sourcesProvider;
import 'filters_sheet.dart';
import 'search_controller.dart';

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _text.text = ref.read(searchControllerProvider).query;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
        ref.read(searchControllerProvider.notifier).loadMore();
      }
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _setQuery(String q) {
    _text.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    ref.read(searchControllerProvider.notifier)
      ..setQuery(q)
      ..submit();
    ref.invalidate(searchHistoryProvider);
  }

  Future<void> _openFilters() async {
    final st = ref.read(searchControllerProvider);
    final result = await showFiltersSheet(
      context,
      initial: st.filters,
      genres: [for (final g in commonGenres) Genre(g, g)],
    );
    if (result != null) ref.read(searchControllerProvider.notifier).setFilters(result);
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(searchControllerProvider);
    final sources = ref.watch(sourcesProvider).valueOrNull ?? const <SourceInfo>[];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, MfSpace.sm),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      focusNode: _focus,
                      textInputAction: TextInputAction.search,
                      onChanged: ref.read(searchControllerProvider.notifier).setQuery,
                      onSubmitted: (_) {
                        ref.read(searchControllerProvider.notifier).submit();
                        ref.invalidate(searchHistoryProvider);
                      },
                      decoration: InputDecoration(
                        hintText: 'Название манги, манхвы, маньхуа…',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: st.query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Очистить',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _text.clear();
                                  ref.read(searchControllerProvider.notifier).setQuery('');
                                },
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: MfSpace.sm),
                  Badge(
                    isLabelVisible: st.filters.activeCount > 0,
                    label: Text('${st.filters.activeCount}'),
                    child: IconButton.filledTonal(
                      tooltip: 'Фильтры',
                      onPressed: _openFilters,
                      icon: const Icon(Icons.tune_rounded),
                    ),
                  ),
                ]),
              ),
            ),
            if (sources.length > 1)
              SliverToBoxAdapter(child: _SourceFilter(sources: sources, selected: st.sources)),
            if (st.isIdle)
              ..._idle(context, sources)
            else
              ..._results(context, st),
            const SliverToBoxAdapter(child: SizedBox(height: MfSpace.huge)),
          ],
        ),
      ),
    );
  }

  List<Widget> _idle(BuildContext context, List<SourceInfo> sources) {
    final history = ref.watch(searchHistoryProvider).valueOrNull ?? const <String>[];
    return [
      if (history.isNotEmpty) ...[
        SliverToBoxAdapter(
          child: SectionHeader(
            title: 'Недавние запросы',
            trailing: TextButton(
              onPressed: () async {
                await ref.read(searchHistoryDaoProvider).clear();
                ref.invalidate(searchHistoryProvider);
              },
              child: const Text('Очистить'),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
            child: Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
              for (final q in history)
                InputChip(
                  label: Text(q),
                  onPressed: () => _setQuery(q),
                  onDeleted: () async {
                    await ref.read(searchHistoryDaoProvider).remove(q);
                    ref.invalidate(searchHistoryProvider);
                  },
                ),
            ]),
          ),
        ),
      ],
      const SliverToBoxAdapter(child: SectionHeader(title: 'Жанры', subtitle: 'Поиск по всем источникам')),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          child: Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
            for (final g in commonGenres.take(14))
              ActionChip(
                label: Text(g),
                onPressed: () {
                  final ctrl = ref.read(searchControllerProvider.notifier);
                  ctrl.setFilters(ref.read(searchControllerProvider).filters.copyWith(genres: [g]));
                },
              ),
          ]),
        ),
      ),
      const SliverToBoxAdapter(child: SectionHeader(title: 'Каталоги источников')),
      SliverList.builder(
        itemCount: sources.length,
        itemBuilder: (context, i) {
          final s = sources[i];
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: context.colors.surfaceContainerHigh,
              child: Text(s.name.characters.first, style: MfType.titleSmall.copyWith(color: MfColors.accent)),
            ),
            title: Text(s.name),
            subtitle: Text(s.notes.isEmpty ? Uri.tryParse(s.baseUrl)?.host ?? s.baseUrl : s.notes,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push(Routes.source(s.id)),
          );
        },
      ),
    ];
  }

  List<Widget> _results(BuildContext context, SearchState st) {
    if (st.loading) return const [GridSkeleton()];
    if (st.error != null) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: ErrorState(error: st.error!, onRetry: ref.read(searchControllerProvider.notifier).submit),
        ),
      ];
    }
    return [
      if (st.errors.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, 0),
            child: Text(
              'Не ответили: ${st.errors.map((e) => e.sourceId).join(', ')}',
              style: context.text.bodySmall?.copyWith(color: context.textTertiary),
            ),
          ),
        ),
      if (st.items.isEmpty)
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(icon: Icons.search_off_rounded, title: 'Ничего не найдено', message: 'Попробуйте другое написание или уберите фильтры'),
        )
      else
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, 0),
          sliver: SliverGrid.builder(
            gridDelegate: coverGridDelegate(context),
            itemCount: st.items.length,
            itemBuilder: (context, i) {
              final c = st.items[i];
              final sourcesLabel = [c.sourceName ?? c.sourceId, ...c.alsoIn.map((x) => x.sourceName ?? x.sourceId)];
              return MangaTile(
                card: c,
                heroPrefix: 'search',
                subtitle: sourcesLabel.join(' · '),
                badge: c.alsoIn.isNotEmpty ? '${c.alsoIn.length + 1}' : null,
                onTap: () => c.alsoIn.isEmpty ? context.push(Routes.title(c.sourceId, c.id)) : _pickSource(c),
              );
            },
          ),
        ),
      if (st.loadingMore)
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.all(MfSpace.xl), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5))),
        ),
    ];
  }

  Future<void> _pickSource(MangaCard c) async {
    final options = [c, ...c.alsoIn];
    final picked = await showModalBottomSheet<MangaCard>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.gutter, MfSpace.md),
            child: Text('Найдено в ${options.length} источниках', style: context.text.titleMedium),
          ),
          for (final o in options)
            ListTile(
              leading: MangaCover(url: o.coverUrl, width: 40, radius: MfRadius.xs, thumbWidth: 160),
              title: Text(o.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(o.sourceName ?? o.sourceId),
              onTap: () => Navigator.pop(context, o),
            ),
          const SizedBox(height: MfSpace.md),
        ]),
      ),
    );
    if (picked != null && mounted) context.push(Routes.title(picked.sourceId, picked.id));
  }
}

class _SourceFilter extends ConsumerWidget {
  const _SourceFilter({required this.sources, required this.selected});
  final List<SourceInfo> sources;
  final List<String>? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctrl = ref.read(searchControllerProvider.notifier);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
        children: [
          ChoiceChip(
            label: const Text('Все источники'),
            selected: selected == null,
            showCheckmark: false,
            onSelected: (_) => ctrl.setSources(null),
          ),
          for (final s in sources) ...[
            const SizedBox(width: MfSpace.sm),
            FilterChip(
              label: Text(s.name),
              selected: selected?.contains(s.id) ?? false,
              onSelected: (v) {
                final next = {...?selected};
                v ? next.add(s.id) : next.remove(s.id);
                ctrl.setSources(next.isEmpty ? null : next.toList());
              },
            ),
          ],
        ],
      ),
    );
  }
}
