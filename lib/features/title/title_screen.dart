import 'dart:async';
import 'dart:math' as math;
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
import '../home/for_you.dart' show SimilarTitlesSection;
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
      data: tint == null ? theme : _coverTheme(theme, tint),
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
      _Header(manga: m, fromCache: data.fromCache, chapters: data.chapters.length),
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
    ];
    // 3.0: chapters right after the description; other sources and similar titles below them
    final extras = <Widget>[
      SliverToBoxAdapter(
        child: OtherSourcesPanel(
          k: k,
          currentMax: data.chapters.fold<double?>(null, (a, c) => c.number == null ? a : (a == null || c.number! > a ? c.number : a)),
        ),
      ),
      SliverToBoxAdapter(child: SimilarTitlesSection(sourceId: m.sourceId, mangaId: m.id, title: m.title)),
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
                if (data.isMerged) _MergedNote(data: data),
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
    ];
    // Tablet: details on the left, chapters on the right.
    if (MediaQuery.sizeOf(context).width >= 900) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 440,
          child: CustomScrollView(slivers: [...top, ...extras, SliverToBoxAdapter(child: SizedBox(height: bottomInset(context, 120)))]),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(child: SizedBox(height: MediaQuery.paddingOf(context).top + MfSpace.md)),
            ...chapterSlivers,
            SliverToBoxAdapter(child: SizedBox(height: bottomInset(context, 120))),
          ]),
        ),
      ]);
    }
    return CustomScrollView(slivers: [
      ...top,
      ...chapterSlivers,
      ...extras,
      SliverToBoxAdapter(child: SizedBox(height: bottomInset(context, 120))),
    ]);
  }
}

/// The whole page in the cover's palette: a tonal scheme seeded by the cover's colour.
/// Built on top of the app theme (same text styles), so [AnimatedTheme] can blend the two.
ThemeData _coverTheme(ThemeData base, Color tint) {
  final t = AppTheme.build(AppTheme.scheme(tint, base.brightness, wallpaper: true));
  return base.copyWith(
    colorScheme: t.colorScheme,
    scaffoldBackgroundColor: t.scaffoldBackgroundColor,
    canvasColor: t.canvasColor,
    appBarTheme: t.appBarTheme,
    filledButtonTheme: t.filledButtonTheme,
    outlinedButtonTheme: t.outlinedButtonTheme,
    textButtonTheme: t.textButtonTheme,
    chipTheme: t.chipTheme,
    progressIndicatorTheme: t.progressIndicatorTheme,
    switchTheme: t.switchTheme,
    checkboxTheme: t.checkboxTheme,
    bottomSheetTheme: t.bottomSheetTheme,
    dialogTheme: t.dialogTheme,
    snackBarTheme: t.snackBarTheme,
    segmentedButtonTheme: t.segmentedButtonTheme,
    dividerTheme: t.dividerTheme,
    listTileTheme: t.listTileTheme,
    iconTheme: t.iconTheme,
  );
}

/// The cover is the hero: the art fills the top of the page, the cover card floats over it in
/// its own colour's glow, and the whole page takes its palette from the cover.
class _Header extends StatelessWidget {
  const _Header({required this.manga, required this.fromCache, required this.chapters});
  final MangaDetails manga;
  final bool fromCache;
  final int chapters;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final top = MediaQuery.paddingOf(context).top;
    final expanded = (size.height * 0.7).clamp(500.0, 640.0) + top * 0.3;
    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: expanded,
      backgroundColor: context.colors.surface,
      surfaceTintColor: Colors.transparent,
      title: _CollapsedTitle(title: manga.title, expandedHeight: expanded),
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
        stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
        collapseMode: CollapseMode.parallax,
        background: Stack(fit: StackFit.expand, children: [
          _CoverBackdrop(url: manga.coverUrl),
          // a soft glow of the cover's own colour behind the card
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, 0.05),
                radius: 0.75,
                colors: [context.colors.primary.withValues(alpha: 0.32), Colors.transparent],
              ),
            ),
          ),
          // legible bar on top, the page's own colour at the bottom
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  context.colors.surface.withValues(alpha: 0.55),
                  context.colors.surface.withValues(alpha: 0.0),
                  context.colors.surface.withValues(alpha: 0.35),
                  context.colors.surface.withValues(alpha: 0.92),
                  context.colors.surface,
                ],
                stops: const [0.0, 0.22, 0.5, 0.78, 1.0],
              ),
            ),
          ),
          Positioned(
            left: MfSpace.gutter,
            right: MfSpace.gutter,
            bottom: MfSpace.lg,
            child: _HeroContent(manga: manga, fromCache: fromCache, chapters: chapters),
          ),
        ]),
      ),
    );
  }
}

/// The cover art, big and slowly drifting (Ken Burns): sharp on top, melting into blur below.
class _CoverBackdrop extends StatefulWidget {
  const _CoverBackdrop({required this.url});
  final String url;

  @override
  State<_CoverBackdrop> createState() => _CoverBackdropState();
}

class _CoverBackdropState extends State<_CoverBackdrop> with SingleTickerProviderStateMixin {
  late final AnimationController _drift = AnimationController(vsync: this, duration: const Duration(seconds: 22));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still) {
      _drift.stop();
    } else if (!_drift.isAnimating) {
      _drift.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty) return ColoredBox(color: context.colors.surfaceContainer);
    final width = (MediaQuery.sizeOf(context).width * MediaQuery.devicePixelRatioOf(context)).round();
    final image = netImage(withWidth(widget.url, width.clamp(320, 900)));
    Widget art(double sigma) {
      final img = Image(image: image, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox());
      return sigma == 0
          ? img
          : ImageFiltered(imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.clamp), child: img);
    }

    return AnimatedBuilder(
      animation: _drift,
      builder: (context, child) {
        final t = Curves.easeInOutSine.transform(_drift.value);
        return Transform.scale(
          scale: 1.08 + 0.08 * t,
          alignment: Alignment(-0.3 + 0.6 * t, -0.4),
          child: child,
        );
      },
      child: Stack(fit: StackFit.expand, children: [
        art(26),
        ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.white, Colors.transparent],
            stops: [0.0, 0.35, 0.7],
          ).createShader(r),
          child: art(1.5),
        ),
      ]),
    );
  }
}

/// Cover card, title, authors and facts — centred, shrinking away as the header collapses.
class _HeroContent extends StatelessWidget {
  const _HeroContent({required this.manga, required this.fromCache, required this.chapters});
  final MangaDetails manga;
  final bool fromCache;
  final int chapters;

  @override
  Widget build(BuildContext context) {
    final settings = context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    var t = 1.0; // 1 = fully open
    if (settings != null && settings.maxExtent > settings.minExtent) {
      t = ((settings.currentExtent - settings.minExtent) / (settings.maxExtent - settings.minExtent)).clamp(0.0, 1.0);
    }
    final glow = context.colors.primary;
    final screen = MediaQuery.sizeOf(context);
    final coverW = (screen.width * 0.46).clamp(130.0, math.min(200.0, screen.height * 0.26)).toDouble();
    final heroTag = 'title-${manga.sourceId}:${manga.id}';
    return Opacity(
      opacity: Curves.easeIn.transform(((t - 0.25) / 0.75).clamp(0.0, 1.0)),
      child: Transform.scale(
        scale: 0.85 + 0.15 * t,
        alignment: Alignment.bottomCenter,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          GestureDetector(
            onTap: () => _openCover(context, manga.coverUrl, heroTag),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(MfRadius.xl),
                boxShadow: [
                  BoxShadow(color: glow.withValues(alpha: 0.55), blurRadius: 48, spreadRadius: -4, offset: const Offset(0, 22)),
                  BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 24, offset: const Offset(0, 12)),
                ],
              ),
              child: Stack(children: [
                MangaCover(url: manga.coverUrl, width: coverW, radius: MfRadius.xl, heroTag: heroTag, shadow: false),
                // a glossy edge, like a printed cover catching the light
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(MfRadius.xl),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: const Alignment(0.2, 0.2),
                          colors: [Colors.white.withValues(alpha: 0.20), Colors.white.withValues(alpha: 0.0)],
                        ),
                      ),
                    ),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: MfSpace.xl),
          GestureDetector(
            onTap: () => showFullTitle(context, manga.title, subtitle: manga.authors.join(', '), altTitles: manga.altTitles),
            child: Text(
              manga.title,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: MfType.display.copyWith(color: context.colors.onSurface, fontSize: 26, height: 1.15),
            ),
          ),
          if (manga.authors.isNotEmpty) ...[
            const SizedBox(height: MfSpace.xs),
            Text(manga.authors.join(', '),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodyMedium?.copyWith(color: context.colors.onSurfaceVariant)),
          ],
          const SizedBox(height: MfSpace.md),
          Wrap(alignment: WrapAlignment.center, spacing: MfSpace.xs, runSpacing: MfSpace.xs, children: [
            _StatusPill(status: manga.status),
            if (manga.kind != null) Tag(manga.kind!.label),
            if (chapters > 0) Tag('$chapters гл.', icon: Icons.menu_book_rounded),
            if (manga.ageRating != null) Tag(manga.ageRating!),
            Tag(manga.sourceName, icon: Icons.public_rounded),
            if (fromCache) const Tag('офлайн', icon: Icons.cloud_off_rounded),
          ]),
        ]),
      ),
    );
  }
}

/// «Онгоинг» with a live dot, «Завершён» calm.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final PubStatus status;

  @override
  Widget build(BuildContext context) {
    final ongoing = status == PubStatus.ongoing;
    final color = ongoing ? const Color(0xFF4CD787) : context.colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(MfRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(status.label, style: MfType.caption.copyWith(color: context.colors.onSurface)),
      ]),
    );
  }
}

/// Tap the cover: it flies out full screen; pinch to look closer, tap or swipe to close.
void _openCover(BuildContext context, String url, Object heroTag) {
  if (url.isEmpty) return;
  HapticFeedback.lightImpact();
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.black.withValues(alpha: 0.92),
    transitionDuration: MfMotion.slow,
    reverseTransitionDuration: MfMotion.base,
    pageBuilder: (context, anim, _) => FadeTransition(
      opacity: anim,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        onVerticalDragEnd: (d) {
          if ((d.primaryVelocity ?? 0).abs() > 300) Navigator.of(context).pop();
        },
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Center(
              child: InteractiveViewer(
                maxScale: 4,
                child: Padding(
                  padding: const EdgeInsets.all(MfSpace.xl),
                  child: Hero(
                    tag: heroTag,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(MfRadius.lg),
                      child: Image(image: netImage(withWidth(url, 1000)), fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  ));
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
                maxLines: _expanded ? null : 3,
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

/// «Главы из 3 источников · +5 с ReManga»: the list is merged from every site that has the title.
class _MergedNote extends StatelessWidget {
  const _MergedNote({required this.data});
  final TitleData data;

  @override
  Widget build(BuildContext context) {
    final added = [for (final s in data.sources.skip(1)) if (s.added > 0) s];
    final text = added.isEmpty
        ? 'Сверено с ${data.sources.length - 1} ${data.sources.length - 1 == 1 ? 'источником' : 'источниками'} — у этого сайта все главы'
        : 'Главы из ${added.length + 1} источников: ${[for (final s in added) '+${s.added} с ${s.sourceName}'].join(', ')}';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(children: [
        Icon(Icons.merge_type_rounded, size: 14, color: context.colors.primary),
        const SizedBox(width: 4),
        Flexible(
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall?.copyWith(color: context.colors.primary)),
        ),
      ]),
    );
  }
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
      // one title, every source: where a chapter the title's own site lacks comes from
      if (chapter.isForeign && chapter.sourceName != null) '↗ ${chapter.sourceName}',
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
          // the same shape as the page about to appear: a big centred cover, title, chips
          const SizedBox(height: MfSpace.xl),
          const Center(child: Skeleton(width: 180, height: 257, radius: MfRadius.xl)),
          const SizedBox(height: MfSpace.xl),
          const Center(child: Skeleton(width: 220, height: 26)),
          const SizedBox(height: MfSpace.sm),
          const Center(child: Skeleton(width: 140, height: 14)),
          const SizedBox(height: MfSpace.md),
          const Center(child: Skeleton(width: 240, height: 26, radius: MfRadius.pill)),
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
