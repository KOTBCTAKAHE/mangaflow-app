import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/network/api_exception.dart';
import '../../core/providers.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/remote/catalog_api.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/states.dart';
import 'filters_sheet.dart';

/// Paginated catalog of one source with its native filters.
class SourceBrowseScreen extends ConsumerStatefulWidget {
  const SourceBrowseScreen({super.key, required this.sourceId});
  final String sourceId;

  @override
  ConsumerState<SourceBrowseScreen> createState() => _SourceBrowseScreenState();
}

class _SourceBrowseScreenState extends ConsumerState<SourceBrowseScreen> {
  final _scroll = ScrollController();
  SourceInfo? _source;
  CatalogFilters _filters = const CatalogFilters();
  final _items = <MangaCard>[];
  int _page = 0;
  bool _hasNext = true;
  bool _loading = false;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 800) _load();
    });
    _init();
  }

  Future<void> _init() async {
    try {
      final s = await ref.read(catalogRepositoryProvider).source(widget.sourceId);
      if (!mounted) return;
      setState(() => _source = s);
    } catch (_) {}
    await _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading && !reset) return;
    if (!reset && !_hasNext) return;
    final gen = reset ? ++_generation : _generation;
    setState(() {
      _loading = true;
      if (reset) {
        _items.clear();
        _page = 0;
        _hasNext = true;
        _error = null;
      }
    });
    try {
      final res = await ref.read(catalogRepositoryProvider).browse(widget.sourceId, page: _page + 1, filters: _filters);
      if (!mounted || gen != _generation) return;
      final seen = {for (final i in _items) i.key};
      setState(() {
        _items.addAll(res.items.where((i) => !seen.contains(i.key)));
        _page = res.page;
        _hasNext = res.hasNext && res.items.isNotEmpty;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _filtersSheet() async {
    final s = _source;
    if (s == null) return;
    final res = await showFiltersSheet(context, initial: _filters, genres: s.genres, caps: s.caps);
    if (res != null) {
      _filters = res;
      await _load(reset: true);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _source;
    return Scaffold(
      appBar: AppBar(
        title: Text(s?.name ?? widget.sourceId),
        actions: [
          if (s != null && s.caps.sortOrders.length > 1)
            PopupMenuButton<SortMode>(
              tooltip: 'Сортировка',
              icon: const Icon(Icons.sort_rounded),
              initialValue: _filters.sort,
              onSelected: (m) {
                _filters = _filters.copyWith(sort: m);
                _load(reset: true);
              },
              itemBuilder: (_) => [for (final m in s.caps.sortOrders) PopupMenuItem(value: m, child: Text(m.label))],
            ),
          IconButton(
            tooltip: 'Фильтры',
            onPressed: _filtersSheet,
            icon: Badge(
              isLabelVisible: _filters.activeCount > 0,
              label: Text('${_filters.activeCount}'),
              child: const Icon(Icons.tune_rounded),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: CustomScrollView(controller: _scroll, slivers: [
          if (_items.isEmpty && _loading)
            const GridSkeleton(count: 12)
          else if (_items.isEmpty && _error != null)
            SliverFillRemaining(hasScrollBody: false, child: ErrorState(error: _error!, onRetry: () => _load(reset: true)))
          else if (_items.isEmpty)
            const SliverFillRemaining(
                hasScrollBody: false, child: EmptyState(icon: Icons.inbox_outlined, title: 'Ничего не найдено'))
          else
            SliverPadding(
              padding: const EdgeInsets.all(MfSpace.gutter),
              sliver: SliverGrid.builder(
                gridDelegate: coverGridDelegate(context),
                itemCount: _items.length,
                itemBuilder: (context, i) => MangaTile(
                  card: _items[i],
                  heroPrefix: 'src',
                  onTap: () => context.push(Routes.title(_items[i].sourceId, _items[i].id)),
                ),
              ),
            ),
          if (_items.isNotEmpty && _loading)
            const SliverToBoxAdapter(
                child: Padding(padding: EdgeInsets.all(MfSpace.xl), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)))),
          if (_items.isNotEmpty && _error != null && !_loading)
            SliverToBoxAdapter(child: ErrorState(error: _error!, compact: true, onRetry: _load)),
          const SliverToBoxAdapter(child: SizedBox(height: MfSpace.huge)),
        ]),
      ),
    );
  }
}
