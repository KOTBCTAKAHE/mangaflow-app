import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../social/social_screens.dart';
import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../core/utils/format.dart';
import '../../data/models/library.dart';
import '../../data/models/manga.dart';
import '../../data/models/reading.dart';
import '../../data/services/download_manager.dart';
import '../../widgets/cover_color.dart';
import '../../widgets/effects.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/net_image.dart';
import '../../data/local/bookmarks_dao.dart';
import 'other_sources.dart';
import '../../widgets/states.dart';
import '../downloads_support.dart';
import '../library/library_actions.dart';
import 'title_providers.dart';

class TitleScreen extends ConsumerStatefulWidget {
  const TitleScreen({super.key, required this.sourceId, required this.mangaId});
  final String sourceId;
  final String mangaId;

  @override
  ConsumerState<TitleScreen> createState() => _TitleScreenState();
}

class _TitleScreenState extends ConsumerState<TitleScreen> {
  late final TitleKey k = (sourceId: widget.sourceId, mangaId: widget.mangaId);
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  Future<void> _refresh() async {
    try {
      final data = await ref.read(catalogRepositoryProvider).title(k.sourceId, k.mangaId, refresh: true);
      await ref.read(libraryRepositoryProvider).refreshSnapshot(data);
    } catch (_) {}
    ref.invalidate(titleProvider(k));
    await ref.read(updatesDaoProvider).markSeen(sourceId: k.sourceId, mangaId: k.mangaId);
  }

  @override
  void initState() {
    super.initState();
    // Opening a title clears its "new chapters" badge.
    Future.microtask(() async {
      await ref.read(updatesDaoProvider).markSeen(sourceId: k.sourceId, mangaId: k.mangaId);
      await ref.read(libraryDaoProvider).setUnread(k.sourceId, k.mangaId, 0);
      ref.read(dataVersionProvider.notifier).state++;
      // fresh positions from other devices (progress list refreshes when the pull lands)
      unawaited(ref.read(syncEngineProvider).sync());
    });
  }

  @override
  Widget build(BuildContext context) {
    final title = ref.watch(titleProvider(k));
    final tint = ref.watch(coverTintProvider(title.valueOrNull?.manga.coverUrl ?? '')).valueOrNull;
    final theme = Theme.of(context);
    return AnimatedTheme(
      data: tint == null ? theme : tintedTheme(theme, tint),
      duration: MfMotion.slow,
      child: PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Scaffold(
        body: title.when(
          loading: () => const _TitleSkeleton(),
          error: (e, _) => Scaffold(
            appBar: AppBar(),
            body: ErrorState(error: e, onRetry: () => ref.invalidate(titleProvider(k))),
          ),
          data: (data) => RefreshIndicator(
            onRefresh: _refresh,
            edgeOffset: 80,
            child: _Body(data: data, k: k, selected: _selected, onSelect: (id) {
              setState(() => _selected.contains(id) ? _selected.remove(id) : _selected.add(id));
            }, onClearSelection: () => setState(_selected.clear)),
          ),
        ),
        extendBody: true,
        bottomNavigationBar: !title.hasValue
            ? null
            : AnimatedSwitcher(
                duration: MfMotion.base,
                child: _selecting
                    ? _SelectionBar(
                        data: title.value!,
                        k: k,
                        selected: _selected,
                        onDone: () => setState(_selected.clear),
                        onSelectAll: () => setState(() => _selected.addAll(title.value!.chapters.map((c) => c.id))),
                      )
                    : _ReadBar(data: title.value!, k: k),
              ),
      ),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.data, required this.k, required this.selected, required this.onSelect, required this.onClearSelection});
  final TitleData data;
  final TitleKey k;
  final Set<String> selected;
  final void Function(String id) onSelect;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = data.manga;
    final progress = ref.watch(titleProgressProvider(k)).valueOrNull ?? const <String, ChapterProgress>{};
    final downloads = ref.watch(titleDownloadsProvider(k)).valueOrNull ?? const <String, DownloadTask>{};
    final asc = ref.watch(chapterOrderAscProvider(k));
    final hideRead = ref.watch(settingsProvider.select((s) => s.hideReadChapters));
    var chapters = asc ? data.chapters.reversed.toList() : data.chapters;
    if (hideRead) chapters = [for (final c in chapters) if (!(progress[c.id]?.completed ?? false)) c];
    final readCount = data.chapters.where((c) => progress[c.id]?.completed ?? false).length;

    final top = <Widget>[
      _Header(manga: m, fromCache: data.fromCache),
      if (data.chapters.isNotEmpty)
        SliverToBoxAdapter(child: _ProgressStrip(read: readCount, total: data.chapters.length)),
      SliverToBoxAdapter(child: _Info(manga: m)),
      SliverToBoxAdapter(child: _TitleBookmarks(k: k)),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          child: TitleSocialPanel(manga: m),
        ),
      ),
      SliverToBoxAdapter(
        child: OtherSourcesPanel(
          k: k,
          currentMax: data.chapters.fold<double?>(null, (a, c) => c.number == null ? a : (a == null || c.number! > a ? c.number : a)),
        ),
      ),
    ];
    final chapterSlivers = <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.xxl, MfSpace.sm, MfSpace.sm),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Главы', style: context.text.titleLarge),
                Text('${data.chapters.length} · прочитано $readCount', style: context.text.bodySmall),
              ]),
            ),
            IconButton(
              tooltip: hideRead ? 'Показать прочитанные' : 'Скрыть прочитанные',
              icon: Icon(hideRead ? Icons.visibility_off_outlined : Icons.visibility_outlined),
              onPressed: () => ref.read(settingsProvider.notifier).update((s) => s.copyWith(hideReadChapters: !hideRead)),
            ),
            IconButton(
              tooltip: asc ? 'Сначала новые' : 'Сначала старые',
              icon: Icon(asc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded),
              onPressed: () => ref.read(chapterOrderAscProvider(k).notifier).state = !asc,
            ),
            PopupMenuButton<String>(
              tooltip: 'Ещё',
              onSelected: (v) async {
                final reading = ref.read(readingRepositoryProvider);
                switch (v) {
                  case 'read_all':
                    await reading.markChapters(m, data.chapters, read: true);
                  case 'unread_all':
                    await reading.markChapters(m, data.chapters, read: false);
                  case 'download_unread':
                    final unread = [for (final c in data.chapters) if (!(progress[c.id]?.completed ?? false)) c];
                    if (context.mounted) await startDownloads(context, ref, m, unread.reversed.toList());
                  case 'delete_downloads':
                    await ref.read(downloadManagerProvider).deleteManga(m.sourceId, m.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'read_all', child: Text('Отметить все прочитанными')),
                PopupMenuItem(value: 'unread_all', child: Text('Снять отметки')),
                PopupMenuItem(value: 'download_unread', child: Text('Скачать непрочитанные')),
                PopupMenuItem(value: 'delete_downloads', child: Text('Удалить загрузки')),
              ],
            ),
          ]),
        ),
      ),
      if (chapters.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(MfSpace.xxl),
            child: EmptyState(icon: Icons.menu_book_outlined, title: 'Глав нет', message: 'Источник не вернул доступных глав'),
          ),
        )
      else
        SliverList.builder(
          itemCount: chapters.length,
          itemBuilder: (context, i) {
            final c = chapters[i];
            return _ChapterTile(
              chapter: c,
              progress: progress[c.id],
              download: downloads[c.id],
              selected: selected.contains(c.id),
              selecting: selected.isNotEmpty,
              onTap: () => selected.isNotEmpty
                  ? onSelect(c.id)
                  : context.push(Routes.reader(m.sourceId, m.id, c.id)),
              onLongPress: () {
                HapticFeedback.selectionClick();
                onSelect(c.id);
              },
              onDownload: () => startDownloads(context, ref, m, [c]),
              onDeleteDownload: () => ref.read(downloadManagerProvider).delete(m.sourceId, c.id),
              onRetryDownload: () {
                final t = downloads[c.id];
                if (t != null) ref.read(downloadManagerProvider).retry(t);
              },
            );
          },
        ),
      SliverToBoxAdapter(child: SizedBox(height: bottomInset(context, 120))),
    ];
    // Tablet: details on the left, chapters on the right.
    if (MediaQuery.sizeOf(context).width >= 900) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 440,
          child: CustomScrollView(slivers: [...top, SliverToBoxAdapter(child: SizedBox(height: bottomInset(context, 120)))]),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).top + MfSpace.md)),
            ...chapterSlivers,
          ]),
        ),
      ]);
    }
    return CustomScrollView(slivers: [...top, ...chapterSlivers]);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.manga, required this.fromCache});
  final MangaDetails manga;
  final bool fromCache;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: 340 + top * 0.2,
      backgroundColor: context.colors.surface,
      title: _CollapsedTitle(title: manga.title, expandedHeight: 340 + top * 0.2),
      actions: [
        if (manga.webUrl.isNotEmpty)
          IconButton(
            tooltip: 'Скопировать ссылку',
            icon: const Icon(Icons.link_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: manga.webUrl));
              showSnack(context, 'Ссылка скопирована');
            },
          ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        stretchModes: const [StretchMode.zoomBackground],
        background: Stack(fit: StackFit.expand, children: [
          if (manga.coverUrl.isNotEmpty)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10, tileMode: TileMode.clamp),
              child: Image(image: netImage(withWidth(manga.coverUrl, 160)), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.7, 0.2),
                radius: 1.3,
                colors: [context.colors.primary.withValues(alpha: 0.30), Colors.transparent],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  context.colors.surfaceContainerLowest.withValues(alpha: 0.55),
                  context.colors.surfaceContainerLowest.withValues(alpha: 0.25),
                  context.colors.surfaceContainerLowest.withValues(alpha: 0.85),
                  context.colors.surfaceContainerLowest,
                ],
                stops: const [0.0, 0.3, 0.72, 0.95],
              ),
            ),
          ),
          Positioned(
            left: MfSpace.gutter,
            right: MfSpace.gutter,
            bottom: MfSpace.lg,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              MangaCover(url: manga.coverUrl, width: 132, heroTag: 'title-${manga.sourceId}:${manga.id}'),
              const SizedBox(width: MfSpace.lg),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  GestureDetector(
                    onTap: () => showFullTitle(context, manga.title,
                        subtitle: manga.authors.join(', '), altTitles: manga.altTitles),
                    child: Text(manga.title,
                        style: MfType.headline.copyWith(color: context.colors.onSurface, fontSize: 18, height: 1.25),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (manga.authors.isNotEmpty) ...[
                    const SizedBox(height: MfSpace.xs),
                    Text(manga.authors.join(', '), style: context.text.bodySmall, maxLines: 2),
                  ],
                  const SizedBox(height: MfSpace.sm),
                  Wrap(spacing: MfSpace.xs, runSpacing: MfSpace.xs, children: [
                    Tag(manga.status.label, accent: manga.status == PubStatus.ongoing),
                    if (manga.kind != null) Tag(manga.kind!.label),
                    if (manga.ageRating != null) Tag(manga.ageRating!),
                    Tag(manga.sourceName, icon: Icons.public_rounded),
                    if (fromCache) const Tag('офлайн', icon: Icons.cloud_off_rounded),
                  ]),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Frosted bottom bar: Read/Continue + library + favorite, always in reach of the thumb.
/// Title text that fades into the pinned app bar once the header is collapsed.
class _CollapsedTitle extends StatelessWidget {
  const _CollapsedTitle({required this.title, required this.expandedHeight});
  final String title;
  final double expandedHeight;

  @override
  Widget build(BuildContext context) {
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos == null) return const SizedBox.shrink();
    final start = expandedHeight - kToolbarHeight - 90;
    return ListenableBuilder(
      listenable: pos,
      builder: (context, _) {
        final t = pos.hasPixels ? ((pos.pixels - start) / 60).clamp(0.0, 1.0) : 0.0;
        return Opacity(
          opacity: t,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: MfType.titleSmall.copyWith(color: context.colors.onSurface)),
        );
      },
    );
  }
}

class _ReadBar extends ConsumerWidget {
  const _ReadBar({required this.data, required this.k});
  final TitleData data;
  final TitleKey k;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = ref.watch(titleProgressProvider(k)).valueOrNull ?? const <String, ChapterProgress>{};
    return Glass(
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: MfSpace.md),
          child: _Actions(data: data, k: k, progress: progress),
        ),
      ),
    );
  }
}

/// "Прочитано 34 из 120" with a tinted bar.
class _ProgressStrip extends StatelessWidget {
  const _ProgressStrip({required this.read, required this.total});
  final int read;
  final int total;

  @override
  Widget build(BuildContext context) {
    final f = total == 0 ? 0.0 : read / total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, 0),
      child: Container(
        padding: const EdgeInsets.all(MfSpace.md),
        decoration: BoxDecoration(
          color: context.colors.surfaceContainer,
          borderRadius: BorderRadius.circular(MfRadius.lg),
        ),
        child: Row(children: [
          SizedBox(
            width: 40,
            height: 40,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: f,
                strokeWidth: 4,
                strokeCap: StrokeCap.round,
                backgroundColor: context.colors.surfaceContainerHighest,
              ),
              Text('${(f * 100).round()}%', style: MfType.caption.copyWith(fontSize: 10, color: context.colors.onSurface)),
            ]),
          ),
          const SizedBox(width: MfSpace.md),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(read == 0 ? 'Ещё не начато' : (read >= total ? 'Прочитано полностью' : 'Прочитано $read из $total'),
                  style: MfType.bodyStrong.copyWith(color: context.colors.onSurface)),
              Text('$total ${_chaptersWord(total)} доступно', style: context.text.bodySmall),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _chaptersWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'глава';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'главы';
    return 'глав';
  }
}

class _Actions extends ConsumerWidget {
  const _Actions({required this.data, required this.k, required this.progress});
  final TitleData data;
  final TitleKey k;
  final Map<String, ChapterProgress> progress;

  /// Next chapter to read: the last one touched (if unfinished) or the one after it.
  (Chapter, int?)? _resume() {
    final ordered = data.chapters.reversed.toList(); // oldest → newest
    if (ordered.isEmpty) return null;
    ChapterProgress? last;
    for (final p in progress.values) {
      if (last == null || p.updatedAt.isAfter(last.updatedAt)) last = p;
    }
    final lp = last;
    if (lp == null) return (ordered.first, null);
    final idx = ordered.indexWhere((c) => c.id == lp.chapterId);
    if (idx < 0) return (ordered.first, null);
    if (!lp.completed) return (ordered[idx], lp.pageIndex);
    return idx + 1 < ordered.length ? (ordered[idx + 1], null) : (ordered[idx], null);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = ref.watch(titleEntryProvider(k)).valueOrNull;
    final resume = _resume();
    final started = progress.isNotEmpty;
    final inLibrary = entry != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.md, MfSpace.gutter, 0),
      child: Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: resume == null
                ? null
                : () => context.push(Routes.reader(k.sourceId, k.mangaId, resume.$1.id, page: resume.$2)),
            icon: const Icon(Icons.play_arrow_rounded),
            label: Text(
              resume == null ? 'Нет глав' : (started ? 'Продолжить · ${resume.$1.title}' : 'Читать'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: MfSpace.sm),
        _SquareButton(
          tooltip: inLibrary ? 'В библиотеке: ${entry.status.label}' : 'В библиотеку',
          icon: inLibrary ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
          active: inLibrary,
          onTap: () async {
            final repo = ref.read(libraryRepositoryProvider);
            HapticFeedback.mediumImpact();
            if (entry == null) {
              await repo.add(data.manga, totalChapters: data.chapters.length,
                  status: started ? LibraryStatus.reading : LibraryStatus.planned);
              if (context.mounted) showSnack(context, 'Добавлено в библиотеку');
            } else {
              if (context.mounted) await showEntryActions(context, ref, entry);
            }
          },
        ),
        const SizedBox(width: MfSpace.sm),
        _SquareButton(
          tooltip: 'Избранное',
          icon: (entry?.isFavorite ?? false) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          active: entry?.isFavorite ?? false,
          onTap: () async {
            final repo = ref.read(libraryRepositoryProvider);
            HapticFeedback.lightImpact();
            if (entry == null) {
              await repo.add(data.manga, totalChapters: data.chapters.length);
              await repo.setFavorite(k.sourceId, k.mangaId, true);
            } else {
              await repo.setFavorite(k.sourceId, k.mangaId, !entry.isFavorite);
            }
          },
        ),
      ]),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({required this.tooltip, required this.icon, required this.onTap, this.active = false});
  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: active ? context.colors.primary.withValues(alpha: 0.16) : context.colors.surfaceContainer,
          borderRadius: BorderRadius.circular(MfRadius.md),
          child: InkWell(
            borderRadius: BorderRadius.circular(MfRadius.md),
            onTap: onTap,
            child: SizedBox(
              width: MfSize.tap,
              height: MfSize.tap,
              child: Icon(icon, color: active ? context.colors.primary : context.colors.onSurface),
            ),
          ),
        ),
      );
}

class _Info extends StatefulWidget {
  const _Info({required this.manga});
  final MangaDetails manga;

  @override
  State<_Info> createState() => _InfoState();
}

class _InfoState extends State<_Info> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final m = widget.manga;
    return Padding(
      padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.xl, MfSpace.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.description.isNotEmpty)
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: AnimatedSize(
              duration: MfMotion.base,
              curve: MfMotion.emphasized,
              alignment: Alignment.topCenter,
              child: Text(
                m.description,
                maxLines: _expanded ? null : 4,
                overflow: _expanded ? TextOverflow.visible : TextOverflow.fade,
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant),
              ),
            ),
          ),
        if (m.genres.isNotEmpty) ...[
          const SizedBox(height: MfSpace.lg),
          Wrap(spacing: MfSpace.sm, runSpacing: MfSpace.sm, children: [for (final g in m.genres) Tag(g)]),
        ],
        if (_expanded || m.description.isEmpty) ...[
          const SizedBox(height: MfSpace.lg),
          if (m.altTitles.isNotEmpty) _Meta('Другие названия', m.altTitles.join(' · ')),
          if (m.authors.isNotEmpty) _Meta('Автор', m.authors.join(', ')),
          if (m.artists.isNotEmpty) _Meta('Художник', m.artists.join(', ')),
          _Meta('Источник', m.sourceName),
        ] else if (m.altTitles.isNotEmpty || m.artists.isNotEmpty)
          TextButton(onPressed: () => setState(() => _expanded = true), child: const Text('Подробнее')),
      ]),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: MfSpace.sm),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(label, style: context.text.bodySmall)),
          Expanded(child: Text(value, style: context.text.bodyMedium)),
        ]),
      );
}

class _ChapterTile extends StatelessWidget {
  const _ChapterTile({
    required this.chapter,
    required this.progress,
    required this.download,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.onDownload,
    required this.onDeleteDownload,
    required this.onRetryDownload,
  });

  final Chapter chapter;
  final ChapterProgress? progress;
  final DownloadTask? download;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onDownload;
  final VoidCallback onDeleteDownload;
  final VoidCallback onRetryDownload;

  @override
  Widget build(BuildContext context) {
    final read = progress?.completed ?? false;
    final inProgress = progress != null && !read && progress!.pageIndex > 0;
    final muted = read ? context.textTertiary : null;
    final sub = [
      if (chapter.uploadedAt != null) formatDate(chapter.uploadedAt!),
      if (chapter.scanlator != null) chapter.scanlator!,
      if (inProgress) 'стр. ${progress!.pageIndex + 1}${progress!.pageCount > 0 ? ' из ${progress!.pageCount}' : ''}',
    ].join(' · ');

    return Material(
      color: selected ? context.colors.primary.withValues(alpha: 0.16) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.only(left: MfSpace.gutter, right: MfSpace.xs),
          child: SizedBox(
            height: 64,
            child: Row(children: [
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(right: MfSpace.md),
                  child: Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      color: selected ? context.colors.primary : context.textTertiary),
                )
              else if (inProgress)
                Padding(
                  padding: EdgeInsets.only(right: MfSpace.md),
                  child: Icon(Icons.circle, size: 8, color: context.colors.primary),
                )
              else if (read)
                Padding(
                  padding: const EdgeInsets.only(right: MfSpace.sm),
                  child: Icon(Icons.check_rounded, size: 16, color: context.textTertiary),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(chapter.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.bodyLarge?.copyWith(color: muted)),
                  if (sub.isNotEmpty)
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.text.labelMedium?.copyWith(color: muted)),
                ]),
              ),
              _DownloadButton(task: download, onDownload: onDownload, onDelete: onDeleteDownload, onRetry: onRetryDownload),
            ]),
          ),
        ),
      ),
    );
  }
}

class _DownloadButton extends StatelessWidget {
  const _DownloadButton({required this.task, required this.onDownload, required this.onDelete, required this.onRetry});
  final DownloadTask? task;
  final VoidCallback onDownload;
  final VoidCallback onDelete;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = task;
    if (t == null) {
      return IconButton(tooltip: 'Скачать', onPressed: onDownload, icon: Icon(Icons.download_outlined, color: context.textTertiary));
    }
    return switch (t.status) {
      DownloadStatus.completed => IconButton(
          tooltip: 'Скачано · удалить',
          onPressed: onDelete,
          icon: const Icon(Icons.download_done_rounded, color: MfColors.success)),
      DownloadStatus.failed => IconButton(
          tooltip: t.error ?? 'Ошибка · повторить', onPressed: onRetry, icon: const Icon(Icons.error_outline_rounded, color: MfColors.danger)),
      DownloadStatus.paused => IconButton(tooltip: 'Пауза', onPressed: onRetry, icon: const Icon(Icons.pause_circle_outline_rounded)),
      DownloadStatus.retrying => IconButton(
          tooltip: 'Повтор позже${t.error != null ? ': ${t.error}' : ''} · нажмите, чтобы повторить сейчас',
          onPressed: onRetry,
          icon: const Icon(Icons.schedule_rounded, color: MfColors.warning)),
      _ => SizedBox(
          width: MfSize.tap,
          height: MfSize.tap,
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, value: t.pageCount == 0 ? null : t.progress),
            ),
          ),
        ),
    };
  }
}

class _SelectionBar extends ConsumerWidget {
  const _SelectionBar(
      {required this.data, required this.k, required this.selected, required this.onDone, required this.onSelectAll});
  final TitleData data;
  final TitleKey k;
  final Set<String> selected;
  final VoidCallback onDone;
  final VoidCallback onSelectAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapters = [for (final c in data.chapters) if (selected.contains(c.id)) c];
    final reading = ref.read(readingRepositoryProvider);
    return BottomAppBar(
      child: Row(children: [
        Text('Выбрано: ${chapters.length}', style: context.text.titleSmall),
        const Spacer(),
        IconButton(
          tooltip: 'Выбрать все',
          icon: const Icon(Icons.select_all_rounded),
          onPressed: onSelectAll,
        ),
        IconButton(
          tooltip: 'Прочитано',
          icon: const Icon(Icons.done_all_rounded),
          onPressed: () async {
            await reading.markChapters(data.manga, chapters, read: true);
            onDone();
          },
        ),
        IconButton(
          tooltip: 'Не прочитано',
          icon: const Icon(Icons.remove_done_rounded),
          onPressed: () async {
            await reading.markChapters(data.manga, chapters, read: false);
            onDone();
          },
        ),
        IconButton(
          tooltip: 'Скачать',
          icon: const Icon(Icons.download_rounded),
          onPressed: () async {
            await startDownloads(context, ref, data.manga, chapters.reversed.toList());
            onDone();
          },
        ),
      ]),
    );
  }
}

class _TitleSkeleton extends StatelessWidget {
  const _TitleSkeleton();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(),
        body: ListView(padding: const EdgeInsets.all(MfSpace.gutter), children: [
          const Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Skeleton(width: 132, height: 188, radius: MfRadius.md),
            SizedBox(width: MfSpace.lg),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Skeleton(height: 22),
                SizedBox(height: MfSpace.sm),
                Skeleton(width: 140, height: 14),
                SizedBox(height: MfSpace.md),
                Skeleton(width: 180, height: 24, radius: MfRadius.pill),
              ]),
            ),
          ]),
          const SizedBox(height: MfSpace.xl),
          const Skeleton(height: MfSize.tap, radius: MfRadius.md),
          const SizedBox(height: MfSpace.xl),
          for (var i = 0; i < 4; i++) ...[const Skeleton(height: 12), const SizedBox(height: MfSpace.sm)],
          const SizedBox(height: MfSpace.xl),
          for (var i = 0; i < 6; i++) ...[const Skeleton(height: 48), const SizedBox(height: MfSpace.sm)],
        ]),
      );
}


final _titleBookmarksProvider = FutureProvider.autoDispose.family<List<Bookmark>, TitleKey>((ref, k) {
  ref.watch(dataVersionProvider);
  return ref.watch(bookmarksDaoProvider).forManga(k.sourceId, k.mangaId);
});

/// Page bookmarks of this title: tap to jump straight to the page.
class _TitleBookmarks extends ConsumerWidget {
  const _TitleBookmarks({required this.k});
  final TitleKey k;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(_titleBookmarksProvider(k)).valueOrNull ?? const <Bookmark>[];
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: MfSpace.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          child: Text('Закладки · ${list.length}', style: MfType.titleSmall.copyWith(color: context.colors.onSurface)),
        ),
        const SizedBox(height: MfSpace.sm),
        SizedBox(
          height: 78,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(width: MfSpace.sm),
            itemBuilder: (context, i) {
              final b = list[i];
              return SizedBox(
                width: 220,
                child: Material(
                  color: context.colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(MfRadius.md),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(MfRadius.md),
                    onTap: () => context.push(Routes.reader(b.sourceId, b.mangaId, b.chapterId, page: b.pageIndex)),
                    child: Padding(
                      padding: const EdgeInsets.all(MfSpace.md),
                      child: Row(children: [
                        Icon(Icons.bookmark_rounded, color: context.colors.primary, size: 20),
                        const SizedBox(width: MfSpace.sm),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('${b.chapterTitle} · стр. ${b.pageIndex + 1}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: MfType.label.copyWith(color: context.colors.onSurface)),
                            if (b.note.isNotEmpty)
                              Text(b.note, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.text.bodySmall),
                          ]),
                        ),
                      ]),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
