import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/remote/catalog_api.dart';

/// Genre names shared by most Russian sources (global search maps names per source).
const commonGenres = [
  'Боевик', 'Боевые искусства', 'Гарем', 'Детектив', 'Драма', 'Исэкай', 'Комедия', 'Магия', 'Меха', 'Мистика',
  'Повседневность', 'Приключения', 'Психология', 'Романтика', 'Сверхъестественное', 'Спорт', 'Трагедия',
  'Триллер', 'Ужасы', 'Фантастика', 'Фэнтези', 'Школа', 'Этти', 'Сёнэн', 'Сэйнэн', 'Сёдзё',
];

/// Bottom sheet with sort / type / status / genre include+exclude.
/// [genres] — the selectable genres (source-specific ids, or names for global search).
Future<CatalogFilters?> showFiltersSheet(
  BuildContext context, {
  required CatalogFilters initial,
  required List<Genre> genres,
  SourceCaps caps = const SourceCaps(genreFilter: true, genreExclude: true, typeFilter: true, statusFilter: true,
      sortOrders: [SortMode.popular, SortMode.updated, SortMode.created, SortMode.rating, SortMode.name]),
  bool showSort = true,
}) =>
    showModalBottomSheet<CatalogFilters>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FiltersSheet(initial: initial, genres: genres, caps: caps, showSort: showSort),
    );

class _FiltersSheet extends StatefulWidget {
  const _FiltersSheet({required this.initial, required this.genres, required this.caps, required this.showSort});
  final CatalogFilters initial;
  final List<Genre> genres;
  final SourceCaps caps;
  final bool showSort;

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late CatalogFilters f = widget.initial;

  /// TriState per genre: include → exclude → none.
  void _cycleGenre(String id) {
    final inc = [...f.genres], exc = [...f.excludeGenres];
    if (inc.contains(id)) {
      inc.remove(id);
      if (widget.caps.genreExclude) exc.add(id);
    } else if (exc.contains(id)) {
      exc.remove(id);
    } else if (widget.caps.genreFilter) {
      inc.add(id);
    } else if (widget.caps.genreExclude) {
      exc.add(id);
    }
    setState(() => f = f.copyWith(genres: inc, excludeGenres: exc));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, 0, MfSpace.sm, MfSpace.sm),
          child: Row(children: [
            Expanded(child: Text('Фильтры', style: context.text.titleLarge)),
            TextButton(
              onPressed: () => setState(() => f = CatalogFilters(query: f.query)),
              child: const Text('Сбросить'),
            ),
          ]),
        ),
        Expanded(
          child: ListView(controller: scroll, padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter), children: [
            if (widget.showSort && widget.caps.sortOrders.length > 1) ...[
              _label(context, 'Сортировка'),
              Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
                for (final s in widget.caps.sortOrders)
                  ChoiceChip(
                    label: Text(s.label),
                    selected: f.sort == s,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => f = f.copyWith(sort: s)),
                  ),
              ]),
            ],
            if (widget.caps.typeFilter) ...[
              _label(context, 'Тип'),
              Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
                for (final k in const [MangaKind.manga, MangaKind.manhwa, MangaKind.manhua, MangaKind.comic])
                  FilterChip(
                    label: Text(k.label),
                    selected: f.kinds.contains(k),
                    onSelected: (v) => setState(() =>
                        f = f.copyWith(kinds: v ? [...f.kinds, k] : f.kinds.where((x) => x != k).toList())),
                  ),
              ]),
            ],
            if (widget.caps.statusFilter) ...[
              _label(context, 'Статус'),
              Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
                for (final s in const [PubStatus.ongoing, PubStatus.completed, PubStatus.hiatus, PubStatus.announced])
                  FilterChip(
                    label: Text(s.label),
                    selected: f.statuses.contains(s),
                    onSelected: (v) => setState(() =>
                        f = f.copyWith(statuses: v ? [...f.statuses, s] : f.statuses.where((x) => x != s).toList())),
                  ),
              ]),
            ],
            if ((widget.caps.genreFilter || widget.caps.genreExclude) && widget.genres.isNotEmpty) ...[
              _label(context, 'Жанры', hint: 'Нажмите один раз — включить, второй — исключить'),
              Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [
                for (final g in widget.genres) _GenreChip(
                  genre: g,
                  state: f.genres.contains(g.id) ? 1 : (f.excludeGenres.contains(g.id) ? 2 : 0),
                  onTap: () => _cycleGenre(g.id),
                ),
              ]),
            ],
            const SizedBox(height: MfSpace.xxl),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, MfSpace.md),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: () => Navigator.pop(context, f), child: const Text('Применить')),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _label(BuildContext context, String text, {String? hint}) => Padding(
        padding: const EdgeInsets.only(top: MfSpace.xl, bottom: MfSpace.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text.toUpperCase(), style: context.text.labelSmall),
          if (hint != null) Text(hint, style: context.text.bodySmall),
        ]),
      );
}

class _GenreChip extends StatelessWidget {
  const _GenreChip({required this.genre, required this.state, required this.onTap});
  final Genre genre;
  final int state; // 0 none, 1 include, 2 exclude
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, icon) = switch (state) {
      1 => (MfColors.accentSoft, MfColors.accent, Icons.add_rounded),
      2 => (MfColors.danger.withValues(alpha: 0.14), MfColors.danger, Icons.remove_rounded),
      _ => (context.colors.surfaceContainer, context.colors.onSurfaceVariant, null),
    };
    return Material(
      color: bg,
      shape: StadiumBorder(side: BorderSide(color: state == 0 ? context.colors.outline : fg.withValues(alpha: 0.4))),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.md, vertical: MfSpace.sm),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 4)],
            Text(genre.name, style: MfType.label.copyWith(color: fg)),
          ]),
        ),
      ),
    );
  }
}
