import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/providers.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tokens.dart';
import '../../data/models/manga.dart';
import '../../data/models/reading.dart';
import '../../widgets/effects.dart';
import '../../widgets/manga_widgets.dart';
import '../../widgets/net_image.dart';
import '../../widgets/states.dart';

final sourcesProvider = FutureProvider<List<SourceInfo>>((ref) {
  ref.watch(settingsProvider.select((s) => (s.showNsfw, s.disabledSources, s.apiBaseUrl, s.sourceLanguages)));
  return ref.watch(catalogRepositoryProvider).enabledSources();
});

final homeFeedProvider = FutureProvider.family<(List<HomeSection>, List<SourceFailure>), String>((ref, sourceId) {
  ref.watch(authProvider);
  return ref.watch(catalogRepositoryProvider).home(sourceId);
});

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider);
    final primary = ref.watch(settingsProvider.select((s) => s.primarySource));
    final list = sources.valueOrNull ?? const <SourceInfo>[];
    final current = list.where((s) => s.id == primary).firstOrNull ?? list.firstOrNull;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(sourcesProvider);
          if (current != null) ref.invalidate(homeFeedProvider(current.id));
          ref.invalidate(continueReadingProvider);
          await ref.read(syncEngineProvider).sync();
        },
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: true,
              snap: true,
              pinned: false,
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              scrolledUnderElevation: 0,
              flexibleSpace: const Glass(border: false, child: SizedBox.expand()),
              titleSpacing: MfSpace.gutter,
              title: Row(children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [MfColors.accent, Color.lerp(MfColors.accent, Colors.white, 0.25)!],
                      begin: Alignment.bottomLeft,
                      end: Alignment.topRight,
                    ),
                    borderRadius: BorderRadius.circular(MfRadius.sm),
                    boxShadow: [BoxShadow(color: MfColors.accent.withValues(alpha: 0.45), blurRadius: 12)],
                  ),
                  child: Icon(Icons.auto_stories_rounded, size: 18, color: MfColors.onAccent),
                ),
                const SizedBox(width: MfSpace.sm),
                Text('MangaFlow', style: MfType.title.copyWith(color: context.colors.onSurface)),
              ]),
              actions: [
                _UpdatesBell(),
                const SizedBox(width: MfSpace.xs),
              ],
            ),
            const SliverToBoxAdapter(child: _Greeting()),
            const SliverToBoxAdapter(child: _ContinueReading()),
            if (sources.hasError && list.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorState(error: sources.error!, onRetry: () => ref.invalidate(sourcesProvider)),
              )
            else if (current == null)
              const SliverToBoxAdapter(child: Column(children: [SizedBox(height: MfSpace.xxl), CarouselSkeleton()]))
            else ...[
              SliverToBoxAdapter(child: _SourceSwitcher(sources: list, current: current)),
              _Feed(source: current),
            ],
            SliverToBoxAdapter(child: SizedBox(height: bottomInset(context, MfSpace.huge))),
          ],
        ),
      ),
    );
  }
}

class _UpdatesBell extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final n = ref.watch(unseenUpdatesProvider).valueOrNull ?? 0;
    return IconButton(
      tooltip: 'Обновления',
      onPressed: () => context.push('/updates'),
      icon: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.notifications_none_rounded)),
    );
  }
}

class _ContinueReading extends ConsumerWidget {
  const _ContinueReading();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(continueReadingProvider).valueOrNull ?? const <ContinueItem>[];
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(title: 'Продолжить чтение', onMore: () => context.push('/history')),
      SizedBox(
        height: 130,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: MfSpace.gutter),
          itemCount: items.length,
          separatorBuilder: (_, __) => const SizedBox(width: MfSpace.md),
          itemBuilder: (context, i) => _ContinueCard(item: items[i]),
        ),
      ),
    ]);
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.item});
  final ContinueItem item;

  @override
  Widget build(BuildContext context) {
    final width = (MediaQuery.sizeOf(context).width * 0.8).clamp(270.0, 380.0);
    return SizedBox(
      width: width,
      child: PressableScale(
        scale: 0.98,
        child: GestureDetector(
          onTap: () => context.push(Routes.reader(item.sourceId, item.mangaId, item.chapterId)),
          onLongPress: () => context.push(Routes.title(item.sourceId, item.mangaId)),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MfRadius.lg),
            child: Stack(fit: StackFit.expand, children: [
              if (item.coverUrl.isNotEmpty)
                ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24, tileMode: TileMode.clamp),
                  child: Transform.scale(
                    scale: 1.4,
                    child: Image(
                      image: netImage(withWidth(item.coverUrl, 160)),
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(),
                    ),
                  ),
                ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [Colors.black.withValues(alpha: 0.35), Colors.black.withValues(alpha: 0.7)],
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
                  borderRadius: BorderRadius.circular(MfRadius.lg),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(MfSpace.md),
                child: Row(children: [
                  MangaCover(url: item.coverUrl, width: 72, radius: MfRadius.sm),
                  const SizedBox(width: MfSpace.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: MfType.titleSmall.copyWith(color: Colors.white)),
                        const SizedBox(height: 2),
                        Text(item.chapterTitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: MfType.bodySmall.copyWith(color: Colors.white70)),
                        const SizedBox(height: MfSpace.md),
                        Row(children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(MfRadius.pill),
                              child: LinearProgressIndicator(
                                value: item.fraction,
                                minHeight: 4,
                                color: MfColors.accent,
                                backgroundColor: Colors.white24,
                              ),
                            ),
                          ),
                          const SizedBox(width: MfSpace.sm),
                          Text('${(item.fraction * 100).round()}%', style: MfType.caption.copyWith(color: Colors.white70)),
                        ]),
                      ],
                    ),
                  ),
                  const SizedBox(width: MfSpace.md),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: MfColors.accent,
                      boxShadow: [BoxShadow(color: MfColors.accent.withValues(alpha: 0.45), blurRadius: 14)],
                    ),
                    child: Icon(Icons.play_arrow_rounded, color: MfColors.onAccent),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// "Добрый вечер" + a short line, sets the tone of the home screen.
class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    final h = DateTime.now().hour;
    final hello = h < 5
        ? 'Доброй ночи'
        : h < 12
            ? 'Доброе утро'
            : h < 18
                ? 'Добрый день'
                : h < 23
                    ? 'Добрый вечер'
                    : 'Доброй ночи';
    return Padding(
      padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.sm, MfSpace.gutter, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hello, style: MfType.headline.copyWith(color: context.colors.onSurface)),
        const SizedBox(height: 2),
        Text(h >= 22 || h < 5 ? 'Самое время для пары глав перед сном' : 'Что почитаем сегодня?',
            style: context.text.bodyMedium?.copyWith(color: context.textTertiary)),
      ]),
    );
  }
}

class _SourceSwitcher extends ConsumerWidget {
  const _SourceSwitcher({required this.sources, required this.current});
  final List<SourceInfo> sources;
  final SourceInfo current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(MfSpace.gutter, MfSpace.lg, MfSpace.gutter, 0),
        itemCount: sources.length,
        separatorBuilder: (_, __) => const SizedBox(width: MfSpace.sm),
        itemBuilder: (context, i) {
          final s = sources[i];
          return ChoiceChip(
            label: Text(s.langBadge == null ? s.name : '${s.name} · ${s.langBadge}'),
            selected: s.id == current.id,
            showCheckmark: false,
            onSelected: (_) => ref.read(settingsProvider.notifier).update((st) => st.copyWith(primarySource: s.id)),
          );
        },
      ),
    );
  }
}

class _Feed extends ConsumerWidget {
  const _Feed({required this.source});
  final SourceInfo source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider(source.id));
    void open(MangaCard c) => context.push(Routes.title(c.sourceId, c.id));

    return feed.when(
      skipLoadingOnRefresh: true,
      loading: () => SliverList.list(children: const [
        SizedBox(height: MfSpace.xxl),
        CarouselSkeleton(),
        SizedBox(height: MfSpace.xxl),
        CarouselSkeleton(),
      ]),
      error: (e, _) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: MfSpace.xxxl),
          child: ErrorState(error: e, onRetry: () => ref.invalidate(homeFeedProvider(source.id))),
        ),
      ),
      data: (data) {
        final (sections, errors) = data;
        if (sections.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: MfSpace.xxxl),
              child: errors.isNotEmpty
                  ? EmptyState(
                      icon: Icons.public_off_rounded,
                      title: '${source.name} недоступен',
                      message: '${errors.first.message}\nВыберите другой источник выше.',
                      action: OutlinedButton(
                          onPressed: () => ref.invalidate(homeFeedProvider(source.id)), child: const Text('Повторить')),
                    )
                  : const EmptyState(icon: Icons.inbox_outlined, title: 'Пока пусто'),
            ),
          );
        }
        final heroItems = [
          for (final c in sections.first.items)
            if (c.coverUrl.isNotEmpty) c
        ].take(6).toList();
        return SliverList.list(children: [
          if (heroItems.length >= 2) HeroBanner(items: heroItems, onOpen: open),
          for (final s in sections) ...[
            SectionHeader(
              title: s.title,
              subtitle: s.key == 'recommended' ? 'На основе вашей библиотеки' : source.name,
              onMore: () => context.push(Routes.source(source.id)),
            ),
            CoverCarousel(items: s.items, onTap: open, heroPrefix: 'home-${s.key}'),
          ],
        ]);
      },
    );
  }
}

/// Auto-advancing banner of featured titles with a blurred cover backdrop.
class HeroBanner extends StatefulWidget {
  const HeroBanner({super.key, required this.items, required this.onOpen});
  final List<MangaCard> items;
  final void Function(MangaCard) onOpen;

  @override
  State<HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<HeroBanner> {
  final _ctrl = PageController(viewportFraction: 0.9);
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _restart();
  }

  void _restart() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_ctrl.hasClients) return;
      final next = (_page + 1) % widget.items.length;
      _ctrl.animateToPage(next, duration: const Duration(milliseconds: 650), curve: MfMotion.emphasized);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return Padding(
      padding: const EdgeInsets.only(top: MfSpace.lg),
      child: Column(children: [
        SizedBox(
          height: 236,
          child: Listener(
            onPointerDown: (_) => _timer?.cancel(),
            onPointerUp: (_) => _restart(),
            child: PageView.builder(
              controller: _ctrl,
              itemCount: items.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (context, i) => AnimatedBuilder(
                animation: _ctrl,
                builder: (context, child) {
                  var d = 0.0;
                  if (_ctrl.hasClients && _ctrl.position.haveDimensions) d = ((_ctrl.page ?? 0) - i).abs().clamp(0.0, 1.0);
                  return Transform.scale(scale: 1 - d * 0.06, child: Opacity(opacity: 1 - d * 0.35, child: child));
                },
                child: _HeroCard(card: items[i], onTap: () => widget.onOpen(items[i])),
              ),
            ),
          ),
        ),
        const SizedBox(height: MfSpace.md),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (var i = 0; i < items.length; i++)
            AnimatedContainer(
              duration: MfMotion.base,
              curve: MfMotion.emphasized,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: i == _page ? 18 : 6,
              height: 6,
              decoration: BoxDecoration(
                color: i == _page ? MfColors.accent : context.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(MfRadius.pill),
              ),
            ),
        ]),
      ]),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.card, required this.onTap});
  final MangaCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final meta = [if (card.kind != null) card.kind!.label, if (card.sourceName != null) card.sourceName!].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: MfSpace.xs),
      child: PressableScale(
        scale: 0.98,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: () => showFullTitle(context, card.title, subtitle: meta, onOpen: onTap),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MfRadius.xl),
            child: Stack(fit: StackFit.expand, children: [
              ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28, tileMode: TileMode.clamp),
                child: Transform.scale(
                  scale: 1.3,
                  child: Image(
                    image: netImage(withWidth(card.coverUrl, 160)),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => ColoredBox(color: context.colors.surfaceContainer),
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black.withValues(alpha: 0.15), Colors.black.withValues(alpha: 0.72)],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(MfSpace.lg),
                child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  MangaCover(url: card.coverUrl, width: 132, radius: MfRadius.md, heroTag: 'hero-${card.key}'),
                  const SizedBox(width: MfSpace.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: MfColors.accent.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(MfRadius.pill),
                          ),
                          child: Text('В тренде', style: MfType.caption.copyWith(color: MfColors.onAccent)),
                        ),
                        const SizedBox(height: MfSpace.sm),
                        Text(
                          card.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: MfType.title.copyWith(color: Colors.white, height: 1.2),
                        ),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: MfSpace.xs),
                          Text(meta, style: MfType.caption.copyWith(color: Colors.white70)),
                        ],
                        const SizedBox(height: MfSpace.md),
                        FilledButton.icon(
                          onPressed: onTap,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: MfSpace.lg),
                          ),
                          icon: const Icon(Icons.menu_book_rounded, size: 18),
                          label: const Text('Читать'),
                        ),
                      ],
                    ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
